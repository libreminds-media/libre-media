#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Pull an event's originals out of OneDrive into inbox/<slug>/.
#
#   make import SLUG=2025-kcd-bengaluru SRC="Photos/KCD Bengaluru 2025"
#   make import SLUG=2025-kcd-bengaluru SRC="..." DRY=1     show what would copy
#
# SRC is a path INSIDE the OneDrive account, as rclone sees it -- not a share
# link. A 1drv.ms or sharepoint.com "share" URL cannot be used here; see README
# "Importing from OneDrive".
#
# Images land in inbox/<slug>/photos/, video in inbox/<slug>/videos/, matching
# the layout build_album.py expects. Nothing is ever deleted: this uses `rclone
# copy` only. `sync`, `move`, `delete` and `purge` are deliberately absent, so a
# mistake in SRC can cost you a wasted download and nothing else.
#
# Like publish.sh, this runs itself twice: once on the host to drive docker, and
# once inside the tools container where rclone lives. IN_TOOLS=1 marks the inner
# pass.

set -euo pipefail

SLUG="${SLUG:-}"
SRC="${SRC:-}"
DRY="${DRY:-0}"

die()  { echo "import: error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "import: warning: $*" >&2; }

[ -n "$SLUG" ] || die "SLUG is required, e.g. make import SLUG=2025-kcd-bengaluru SRC=\"Photos/KCD 2025\""
[ -n "$SRC" ]  || die "SRC is required: the folder path inside the OneDrive account, e.g. SRC=\"Photos/KCD 2025\""
case "$SLUG" in
  */*|.*|"") die "invalid SLUG: $SLUG" ;;
esac
case "$SRC" in
  http*|*1drv.ms*) die "SRC looks like a share link.
  rclone cannot use 1drv.ms or sharepoint.com share URLs. Use the folder's path
  inside the account instead, e.g. SRC=\"Photos/KCD Bengaluru 2025\".
  List what is available with:  make onedrive-ls" ;;
esac

# Extensions we accept. --ignore-case makes these match .JPG, .HEIC, .MOV too;
# verified against this rclone build rather than assumed.
PHOTO_GLOB='*.{jpg,jpeg,png,heic}'
VIDEO_GLOB='*.{mp4,mov}'

if [ "$DRY" = "1" ]; then
  RCLONE_DRY=(--dry-run)
  info "DRY RUN -- nothing will be downloaded or created"
else
  RCLONE_DRY=()
fi


# ===========================================================================
# Inner pass: inside the tools container
# ===========================================================================
if [ "${IN_TOOLS:-0}" = "1" ]; then

  rclone listremotes 2>/dev/null | grep -qx 'onedrive:' \
    || die "no 'onedrive' remote configured.
  Expected a [onedrive] stanza in .config/rclone/rclone.conf.
  See README \"Importing from OneDrive\" for the one-time token setup."

  PHOTOS="inbox/${SLUG}/photos"
  VIDEOS="inbox/${SLUG}/videos"
  # A dry run must leave the filesystem exactly as it found it, including not
  # leaving empty directories behind. rclone's own --dry-run does not need the
  # destination to exist in order to list what it would copy.
  if [ "$DRY" = "1" ]; then
    info "would create ${PHOTOS} and ${VIDEOS}"
  else
    mkdir -p "$PHOTOS" "$VIDEOS"
  fi

  # --size-only: treat a file already present at the same size as done. Photos
  # come off a phone once and never change; re-downloading gigabytes because a
  # modification time drifted is pure waste.
  COMMON=(
    "${RCLONE_DRY[@]}"
    --ignore-case
    --size-only
    --progress
    --stats-one-line
    --transfers 8
    --checkers 16
  )

  info "images: onedrive:${SRC} -> ${PHOTOS}"
  rclone copy "onedrive:${SRC}" "$PHOTOS" "${COMMON[@]}" --include "$PHOTO_GLOB"

  info "video:  onedrive:${SRC} -> ${VIDEOS}"
  rclone copy "onedrive:${SRC}" "$VIDEOS" "${COMMON[@]}" --include "$VIDEO_GLOB"

  # --- album.yaml scaffold ---------------------------------------------------
  YAML="inbox/${SLUG}/album.yaml"
  if [ -e "$YAML" ]; then
    info "${YAML} already exists; leaving it alone"
  elif [ "$DRY" = "1" ]; then
    info "would create ${YAML} from the template"
  else
    # Title from the slug: 2025-kcd-bengaluru -> "Kcd Bengaluru 2025".
    year="${SLUG%%-*}"
    rest="${SLUG#*-}"
    title="$(echo "$rest" | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g') ${year}"
    cat > "$YAML" <<YAMLEOF
# Album metadata. Edit this, then: make publish SLUG=${SLUG}
title: ${title}
date: YYYY-MM-DD          # REQUIRED -- the day of the event, not today
description: 
credit: 
# license: defaults to CC BY-SA 4.0 when omitted. Set it if this album differs.
# license: CC BY 4.0
# youtube:                # optional: video ids already on YouTube
#   - kJQP7kiw5Fk
YAMLEOF
    info "created ${YAML} from the template"
  fi

  if [ "$DRY" != "1" ]; then
    nphoto=$(find "$PHOTOS" -type f 2>/dev/null | wc -l)
    nvideo=$(find "$VIDEOS" -type f 2>/dev/null | wc -l)
    echo
    info "inbox/${SLUG}: ${nphoto} image(s), ${nvideo} video(s)"
  fi
  exit 0
fi


# ===========================================================================
# Outer pass: on the host
# ===========================================================================
cd "$(dirname "$0")/.."

[ -f .env ] || die ".env not found"
CONF=".config/rclone/rclone.conf"
[ -f "$CONF" ] || die "$CONF not found.
  OneDrive needs a one-time token. See README \"Importing from OneDrive\"."

perm="$(stat -c '%a' "$CONF")"
[ "$perm" = "600" ] || die "$CONF is mode $perm, must be 600 -- it holds an OAuth
  refresh token. Fix with: chmod 600 $CONF"

TTY_FLAG=()
[ -t 1 ] || TTY_FLAG=(-T)

docker compose --profile tools run --rm "${TTY_FLAG[@]}" \
  -e IN_TOOLS=1 -e SLUG="$SLUG" -e SRC="$SRC" -e DRY="$DRY" \
  tools pipeline/import.sh

if [ "$DRY" = "1" ]; then
  echo
  info "dry run complete -- nothing was downloaded"
  exit 0
fi

echo
info "next: edit inbox/${SLUG}/album.yaml then run make publish SLUG=${SLUG}"
