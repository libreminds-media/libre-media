# SPDX-License-Identifier: GPL-3.0-or-later
#
# libre-media build/publish toolbox.
#
# Everything that processes media or talks to B2 runs in here. Pillow, ffmpeg
# and rclone are NEVER installed on the host (CLAUDE.md §3).
FROM python:3-slim

# ffmpeg  — video transcode + poster frames
# git     — parity with the host-side publish step
# tini    — reap ffmpeg children cleanly when a publish is interrupted
# curl/unzip — only to fetch rclone below; kept because publish scripts may use curl
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ffmpeg \
      git \
      tini \
      curl \
      unzip \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# rclone from the OFFICIAL release, not Debian's package: Debian trixie ships
# 1.60.1-DEV, which is years behind and carries its own B2 backend quirks.
# Pinned by version and verified against the upstream SHA256SUMS, so this build
# is reproducible and a tampered download fails the build rather than shipping.
# NOTE: the ARG must NOT be named RCLONE_*. Docker exposes build args as
# environment variables, and rclone maps every RCLONE_<FLAG> env var onto the
# CLI flag of that name -- so ARG RCLONE_VERSION makes `rclone version` fail
# with: Invalid value when setting --version from environment variable.
ARG TOOLS_RCLONE_VERSION=1.75.1
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) rcarch=amd64 ;; \
      arm64) rcarch=arm64 ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    pkg="rclone-v${TOOLS_RCLONE_VERSION}-linux-${rcarch}"; \
    cd /tmp; \
    curl -fsSL -O "https://downloads.rclone.org/v${TOOLS_RCLONE_VERSION}/${pkg}.zip"; \
    curl -fsSL -O "https://downloads.rclone.org/v${TOOLS_RCLONE_VERSION}/SHA256SUMS"; \
    grep " ${pkg}.zip\$" SHA256SUMS | sha256sum -c -; \
    unzip -q "${pkg}.zip"; \
    install -m 0755 "${pkg}/rclone" /usr/local/bin/rclone; \
    rm -rf /tmp/rclone-* /tmp/SHA256SUMS; \
    rclone version

# pillow-heif: iPhone originals arrive as .heic, which Pillow cannot open on
# its own. Registering its opener (see pipeline/build_album.py) makes HEIC just
# another input format.
RUN pip install --no-cache-dir --root-user-action=ignore \
      "pillow>=10" \
      "pyyaml>=6" \
      "pillow-heif>=0.16"

# The container runs as the invoking user (see `user:` in docker-compose.yml),
# who has no home directory in this image. HOME=/tmp is set in compose.
WORKDIR /work

ENTRYPOINT ["/bin/bash"]
