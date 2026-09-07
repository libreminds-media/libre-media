#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Publish one album: build derivatives, upload to B2, install the manifest,
# refresh the album index, mirror album JSON to B2, commit.
#
#   make publish SLUG=2025-kcd-bengaluru          real
#   make publish SLUG=2025-kcd-bengaluru DRY=1    show what would happen
#   make publish-dry SLUG=2025-kcd-bengaluru      same thing
#
# NOTE: do NOT use `--dry-run` on the make command line -- that is GNU make's
# own flag and make would refuse to run anything at all. Use DRY=1.
#
# This script runs itself twice: once on the host (git + docker orchestration)
# and once inside the `tools` container (Pillow/ffmpeg/rclone, CLAUDE.md §3).
# IN_TOOLS=1 marks the inner pass.

set -euo pipefail

SLUG="${SLUG:-}"
DRY="${DRY:-0}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"

die()  { echo "publish: error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "publish: warning: $*" >&2; }

[ -n "$SLUG" ] || die "SLUG is required, e.g. make publish SLUG=2025-kcd-bengaluru"
case "$SLUG" in
  */*|.*|"") die "invalid SLUG: $SLUG" ;;
esac

if [ "$DRY" = "1" ]; then
  RCLONE_DRY=(--dry-run)
  info "DRY RUN -- no uploads, no local writes, no commit"
else
  RCLONE_DRY=()
fi


# ===========================================================================
# Inner pass: inside the tools container
# ===========================================================================
if [ "${IN_TOOLS:-0}" = "1" ]; then
  : "${B2_BUCKET:?B2_BUCKET not set in the container environment}"

  BUILD="inbox/${SLUG}/_build"

  info "building derivatives"
  python3 pipeline/build_album.py "$SLUG"

  info "uploading media to b2:${B2_BUCKET}/events/${SLUG}/"
  # `copy`, never `sync` -- sync can delete, and media is immutable (CLAUDE.md §6,§7).
  # --immutable makes rclone fail rather than overwrite an existing object, which
  # is the belt to the content-hashed-filename braces.
  rclone copy "${BUILD}" "b2:${B2_BUCKET}/events/${SLUG}/" \
    "${RCLONE_DRY[@]}" \
    --immutable \
    --exclude "manifest.json" \
    --exclude ".cache.json" \
    --exclude ".tmp/**" \
    --transfers 8 --checkers 16 \
    --progress --stats-one-line

  if [ "$DRY" = "1" ]; then
    info "would install ${BUILD}/manifest.json -> web/albums/${SLUG}.json"
    info "would rebuild web/albums/index.json"
    info "would mirror web/albums/ -> b2:${B2_BUCKET}/_site/albums/"
    echo
    info "manifest preview:"
    python3 -c "import json,sys; m=json.load(open('${BUILD}/manifest.json')); \
print(json.dumps({k:v for k,v in m.items() if k!='items'}, indent=2)); \
print('items:', len(m['items'])); \
[print('  ', i['type'], i['src']) for i in m['items'][:10]]"
    exit 0
  fi

  info "installing manifest -> web/albums/${SLUG}.json"
  cp "${BUILD}/manifest.json" "web/albums/${SLUG}.json"

  info "rebuilding album index"
  python3 pipeline/update_index.py

  # DELIBERATELY NO --immutable here. Album JSON is mutable by design: adding a
  # photo to an existing album rewrites <slug>.json and index.json, and
  # --immutable would make that fail. Only events/ (content-hashed media) is
  # immutable. Do not "fix" this by adding the flag.
  info "mirroring album JSON to b2:${B2_BUCKET}/_site/albums/"
  rclone copy web/albums "b2:${B2_BUCKET}/_site/albums/" \
    --transfers 4 --stats-one-line

  info "container work done"
  exit 0
fi


# ===========================================================================
# Outer pass: on the host
# ===========================================================================
cd "$(dirname "$0")/.."

[ -f .env ] || die ".env not found. cp .env.example .env && chmod 600 .env"
[ -d "inbox/${SLUG}" ] || die "inbox/${SLUG} does not exist"

# --- refuse to publish on top of unrelated work ----------------------------
# We are going to make a commit. If the tree already has changes outside
# web/albums/, that commit would either sweep them up or leave a confusing
# half-state. Stop instead.
DIRTY="$(git status --porcelain -- . ':(exclude)web/albums' 2>/dev/null || true)"
if [ -n "$DIRTY" ]; then
  echo "publish: the working tree has uncommitted changes outside web/albums/:" >&2
  echo "$DIRTY" | sed 's/^/    /' >&2
  if [ "$DRY" = "1" ]; then
    warn "continuing anyway because DRY=1 makes no commit"
  elif [ "$ALLOW_DIRTY" = "1" ]; then
    warn "continuing anyway because ALLOW_DIRTY=1"
  else
    echo >&2
    die "commit or stash them first, or re-run with ALLOW_DIRTY=1"
  fi
fi

if [ "$DRY" != "1" ]; then
  git config user.email >/dev/null 2>&1 \
    || die "git has no user.email configured; publish.sh cannot commit.
  Fix with: git config user.email you@example.org && git config user.name 'Your Name'"
fi

TTY_FLAG=()
[ -t 1 ] || TTY_FLAG=(-T)

info "running build+upload inside the tools container"
docker compose --profile tools run --rm "${TTY_FLAG[@]}" \
  -e IN_TOOLS=1 -e SLUG="$SLUG" -e DRY="$DRY" \
  tools pipeline/publish.sh

if [ "$DRY" = "1" ]; then
  info "dry run complete -- nothing was uploaded, written or committed"
  exit 0
fi

info "committing album metadata"
git add -- web/albums
if git diff --cached --quiet -- web/albums; then
  info "web/albums/ unchanged; nothing to commit"
else
  git commit -q -m "album: ${SLUG}" -- web/albums
  info "committed: $(git log -1 --oneline)"
fi

# --- push -------------------------------------------------------------------
# A failed push must never fail the publish. By this point the album is already
# live on the site and its metadata is mirrored to B2, so nothing is lost -- the
# repository is just temporarily ahead of origin, which is a "push it later"
# problem, not a broken publish. Hence the warning and exit 0.
if git remote get-url origin >/dev/null 2>&1; then
  info "pushing to origin/main"
  if git push origin main; then
    info "pushed: $(git rev-parse --short main) -> origin/main"
  else
    echo >&2
    warn "PUSH FAILED. The album is live and its metadata is mirrored to B2,"
    warn "so nothing is lost -- but this server's repository is now ahead of"
    warn "origin, and a new server rebuilt by 'git clone' would miss this album."
    warn "Retry when you can:"
    warn "    cd $(pwd) && sudo -u libremedia git push origin main"
  fi
else
  warn "no git remote configured; skipping push."
  warn "The album is live and mirrored to B2, but this repository is not a"
  warn "second copy until you add a remote. See MIGRATE.md step 8b."
fi

echo
info "published: https://$(grep -E '^SITE_HOST=' .env | cut -d= -f2-)/album.html?a=${SLUG}"
