# libre-media — LibreMinds event photo & video gallery

Self-hosted gallery at https://photos.libreminds.org. Static pages + lightGallery v2
in a container behind caddy-docker-proxy; media bytes live in a Backblaze B2 bucket and
are served through a local nginx caching proxy under `/media/`.

## Non-negotiable constraints

1. **Everything lives under `/home/libre-media`.** No files, cron entries, systemd units or
   packages outside this directory except a single optional crontab line that calls
   `make backup`. Host-specific values go in `.env`, never hard-coded.
2. **Portable by design.** Moving to a new server must be: install Docker + caddy-docker-proxy,
   `git clone`, copy `.env`, `make restore`, `make up`. Write and keep `MIGRATE.md` accurate.
3. **No host tooling.** Pillow / ffmpeg / rclone run inside the `tools` container
   (`profiles: [tools]`), never installed on the host.
4. **Do not touch other containers or Caddy config on this host.** Only interact with the
   external Caddy network named in `.env` (`CADDY_NETWORK`).
5. **Secrets only in `.env`** (git-ignored, chmod 600). Never write keys into any other file,
   log, or commit. Never `docker compose up` without first running `docker compose config`
   and `nginx -t` inside the relevant image.
6. **Media files are immutable.** Content-hashed filenames; never overwrite, only add.
7. Ask before: starting/stopping containers, deleting anything, running `rclone sync`
   (sync can delete), or changing anything in `.env`.

## Architecture

```
photos.libreminds.org ─► caddy-docker-proxy (auto TLS, labels in docker-compose.yml)
   ├─ /*        → web    (nginx:alpine, ./web  → static index.html, album.html, albums/*.json)
   └─ /media/*  → cache  (nginx:alpine, proxy_cache → B2 friendly URL, slice ranges for video)
tools (profile) → build_album.py + rclone: inbox/<slug> → B2 events/<slug>/ + web/albums/<slug>.json
```

## Directory layout

```
/home/libre-media/
├── CLAUDE.md  README.md  MIGRATE.md  LICENSE  Makefile  docker-compose.yml
├── .env.example        # documented template; .env is git-ignored
├── web/                # served as-is — nothing but public files may live here
│   ├── index.html      # album list, reads albums/index.json
│   ├── album.html      # lightGallery page, ?a=<slug>, reads albums/<slug>.json
│   ├── assets/
│   │   ├── style.css   # shared styles for both pages
│   │   ├── config.js   # single definition of MEDIA_BASE ("/media/") + lg licence hook
│   │   ├── media.js    # shared helpers: mediaUrl(base, rel), esc, formatDate, getJSON
│   │   └── lightgallery/  # vendored v2 (core + thumbnail, zoom, video, fullscreen, hash, share)
│   └── albums/         # index.json + <slug>.json — the only state on this server; backed up
├── webconf/
│   └── default.conf.template  # nginx config for the `web` service. NOT under web/,
│                              # which is served as-is and would expose it.
├── cache/
│   ├── nginx.conf.template    # B2 caching proxy; B2 host & bucket templated from .env via envsubst
│   └── 05-cache-perms.sh      # /docker-entrypoint.d hook; chowns the bind-mounted cache dir
│                              # so the unprivileged nginx worker can write to it
├── cache-data/         # nginx cache, git-ignored, disposable
├── tools/Dockerfile    # python:3-slim + pillow pyyaml ffmpeg + rclone (pinned official release)
├── pipeline/
│   ├── build_album.py  # inbox/<slug> → thumb/ (400px webp) display/ (1920px jpg) video/ (h264 mp4+poster) manifest.json
│   ├── update_index.py # rebuilds web/albums/index.json from every <slug>.json
│   ├── publish.sh      # build → rclone copy → install manifest → update index.json → mirror albums/ to B2 → git commit
│   ├── backup.sh       # rclone copy web/albums + inbox metadata → b2:<bucket>/_site/
│   ├── restore.sh      # reverse of backup.sh; TARGET= restores into a scratch dir
│   ├── migrate_check.sh      # backs `make migrate-check`
│   └── vendor_lightgallery.sh # backs `make vendor-lightgallery`; build-time fetch only
└── inbox/              # git-ignored; volunteer drop zone: <slug>/{album.yaml, photos/, videos/}
```

## Conventions

- Slug: `<yyyy>-<event-name>` e.g. `2025-kcd-bengaluru`. Bucket key: `events/<slug>/...`
- `album.yaml`: `title`, `date` (YYYY-MM-DD), `description`, `credit`, `license`, `youtube: [ids]`
  `license` defaults to `CC BY-SA 4.0` when omitted; media is licensed per album, code is GPL-3.0-or-later
- Manifest item: `{type: image|video|youtube, id, w, h, thumb, src, poster?}` paths relative to `events/<slug>/`
- Cache-Control: web → `public, max-age=300`; media → `public, max-age=31536000, immutable`
- lightGallery licence: GPLv3 if this repo is public under a compatible licence; otherwise `LG_LICENSE_KEY` in `.env`

## Commands (Makefile)

`make up` `make down` `make logs` `make check` (compose config + nginx -t) `make publish SLUG=`
`make backup` `make restore` `make cache-stats` `make cache-clear` `make migrate-check` (verifies
everything needed for a move exists and .env is complete) `make build` `make index` `make shell`
`make publish-dry SLUG=` `make vendor-lightgallery`

Dry runs use `DRY=1`, never `--dry-run` (that is GNU make's own flag).

## Definition of done for any task

- `make check` passes; `curl -I` shows expected status and `X-Cache` header on media
- README.md and MIGRATE.md updated if behaviour or steps changed
- No secrets in tracked files (`git grep -i -E 'key|secret' -- ':!*.example'` is clean)
