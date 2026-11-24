#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Make sure the tools image exists before anything tries to use it.
#
# The image is built locally from tools/Dockerfile and never pushed to a
# registry, so `docker compose run tools` cannot pull it. When the image is
# absent compose tries anyway, fails with "pull access denied", and then
# rebuilds from scratch -- several minutes and ~1,400 lines of build output
# dumped into whatever command happened to trigger it. During the 03:17 cron
# backup that means the job spends its first minutes rebuilding, and
# backup.log fills with docker noise instead of the transfer summary.
#
# The image has vanished three times (2026-10-22, 11-23, 11-24) with nothing
# in any crontab to explain it -- libre-media's own monthly job is
# `docker builder prune -f`, which does not remove images. Rather than depend
# on whatever is removing it stopping, every host-side entry point calls this
# first: the rebuild still happens, but deliberately, with its output in a log
# of its own, and before the real work starts.
#
# Cheap enough to call unconditionally -- one `docker image inspect` when the
# image is present, which is the normal case.

set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="libre-media-tools:latest"
LOG=".tools-build.log"

docker image inspect "$IMAGE" >/dev/null 2>&1 && exit 0

echo "==> ${IMAGE} is missing -- building it first (output: ${LOG})" >&2
start=$(date +%s)
if docker compose --profile tools build tools >"$LOG" 2>&1; then
  echo "==> built ${IMAGE} in $(( $(date +%s) - start ))s" >&2
  exit 0
fi

echo "ensure_tools_image: BUILD FAILED after $(( $(date +%s) - start ))s." >&2
echo "  last lines of ${LOG}:" >&2
tail -15 "$LOG" | sed 's/^/    /' >&2
exit 1
