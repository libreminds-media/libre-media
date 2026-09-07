#!/usr/bin/env bash
#
# Re-download the vendored copy of lightGallery.
#
#   make vendor-lightgallery            # current pinned version
#   make vendor-lightgallery LG=2.9.1   # upgrade
#
# This is a BUILD-TIME fetch only. web/ must never reference a CDN at runtime,
# so afterwards this script fails if any absolute http(s) URL is left behind in
# the vendored CSS or JS.

set -euo pipefail
cd "$(dirname "$0")/.."

LG="${1:-2.9.0}"
DEST="web/assets/lightgallery"
BASE="https://cdn.jsdelivr.net/npm/lightgallery@${LG}"

FILES=(
  lightgallery.umd.js
  css/lightgallery-bundle.css
  plugins/thumbnail/lg-thumbnail.umd.js
  plugins/zoom/lg-zoom.umd.js
  plugins/video/lg-video.umd.js
  plugins/fullscreen/lg-fullscreen.umd.js
  plugins/hash/lg-hash.umd.js
  plugins/share/lg-share.umd.js
  fonts/lg.woff2
  fonts/lg.woff
  fonts/lg.ttf
  fonts/lg.svg
  images/loading.gif
)

echo "==> vendoring lightGallery ${LG} into ${DEST}"
for f in "${FILES[@]}"; do
  mkdir -p "${DEST}/$(dirname "$f")"
  curl -fsSL -m 60 "${BASE}/${f}" -o "${DEST}/${f}"
  printf '    %-46s %8s bytes\n' "$f" "$(stat -c%s "${DEST}/${f}")"
done

cat > "${DEST}/VERSION" <<EOF
lightgallery ${LG}
licence: GPLv3
source:  ${BASE}
vendored: $(date -u +%Y-%m-%d)

Vendored deliberately: web/ has zero runtime CDN dependencies.
Re-vendor with: make vendor-lightgallery LG=<version>
EOF

echo "==> checking for leftover CDN references"
if grep -rlE 'https?://[a-z0-9.-]*(cdn|unpkg|ajax|googleapis)' \
     "${DEST}" --include='*.js' --include='*.css' 2>/dev/null | grep -q .; then
  echo "    FAIL: vendored files still reference a CDN" >&2
  exit 1
fi
echo "    clean"

echo "==> css asset references (must all be relative)"
grep -oE 'url\([^)]*\)' "${DEST}/css/lightgallery-bundle.css" | sort -u | sed 's/^/    /'
