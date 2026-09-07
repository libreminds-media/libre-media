# LibreMinds Event Gallery

Photos and video from LibreMinds events, at **https://photos.libreminds.org**.

Static pages plus [lightGallery v2](https://www.lightgalleryjs.com/) in a container
behind caddy-docker-proxy. The media bytes live in a Backblaze B2 bucket and are
served through a local nginx caching proxy under `/media/`.

Everything lives under `/home/libre-media`. Nothing is installed on the host —
Pillow, ffmpeg and rclone all run inside the `tools` container.

---

## Publishing an album (the short version)

You need three things: a slug, an `album.yaml`, and your files.

```bash
cd /home/libre-media

# 1. Make the drop folder. Slug is <year>-<event-name>, lowercase, hyphenated.
mkdir -p inbox/2025-kcd-bengaluru/{photos,videos}

# 2. Describe the album.
cat > inbox/2025-kcd-bengaluru/album.yaml <<'YAML'
title: KCD Bengaluru 2025
date: 2025-08-16
description: Talks, hallway track and the community dinner.
credit: Photos by the LibreMinds media team
license: CC BY-SA 4.0
youtube:
  - dQw4w9WgXcQ
YAML

# 3. Drop the originals in. Any common format; they get converted for you.
cp ~/event-photos/*.jpg inbox/2025-kcd-bengaluru/photos/
cp ~/event-video/*.mov  inbox/2025-kcd-bengaluru/videos/

# 4. See what would happen. Changes nothing.
make publish-dry SLUG=2025-kcd-bengaluru

# 5. Do it.
make publish SLUG=2025-kcd-bengaluru
```

The album appears at `https://photos.libreminds.org/album.html?a=2025-kcd-bengaluru`
and on the front page.

> **Use `DRY=1`, never `--dry-run`.** `--dry-run` is GNU make's own flag and make
> would simply refuse to run anything. `make publish SLUG=x DRY=1` and
> `make publish-dry SLUG=x` are the same thing.

### `album.yaml` fields

| Field | Required | Notes |
|---|---|---|
| `title` | yes | Shown as the album heading |
| `date` | yes | `YYYY-MM-DD`. Sorts the front page, newest first |
| `description` | no | One or two sentences |
| `credit` | no | Photographer credit, shown under every image |
| `license` | no | Defaults to `CC BY-SA 4.0` if omitted |
| `youtube` | no | List of video IDs. Embedded, not uploaded |

### What publishing actually does

1. **Builds derivatives** in the `tools` container — 400 px WebP thumbnails,
   1920 px JPEGs for the lightbox, h264 MP4 + poster frames for video.
   EXIF is stripped (orientation is applied first), so GPS coordinates and
   camera serial numbers do not go public.
2. **Names every file by its content hash**, so media is immutable — republishing
   never overwrites anything, it only adds. A re-encode that produces identical
   bytes is a no-op.
3. **Uploads** to `b2:<bucket>/events/<slug>/` with `rclone copy` — never `sync`,
   which can delete.
4. **Installs** the manifest as `web/albums/<slug>.json` and rebuilds
   `web/albums/index.json`.
5. **Mirrors** `web/albums/` to `b2:<bucket>/_site/albums/`.
6. **Commits** `web/albums/` as `album: <slug>`.

It refuses to run if the working tree has uncommitted changes outside
`web/albums/` — that commit would otherwise sweep up unrelated work. Override
with `ALLOW_DIRTY=1` if you know what you are doing.

Republishing the same slug is safe and incremental: unchanged sources are read
from `inbox/<slug>/_build/.cache.json` and videos are not re-transcoded.

---

## How media URLs work

This contract is repeated in `web/index.html`, `web/album.html`,
`web/assets/config.js` and `cache/nginx.conf.template`, because if the two ends
ever disagree the site silently 404s.

```
browser                                  cache container
───────────────────────────────────────  ─────────────────────────────────────────
/media/events/<slug>/<path>          ->  https://<B2_DOWNLOAD_HOST>/file/<B2_BUCKET>/events/<slug>/<path>
```

Everything after `/media/` is appended verbatim to the bucket root. Album
manifests store paths relative to their own `base` field, which is always
`events/<slug>/`, so a manifest entry

```json
{ "thumb": "thumb/ab12cd34ef56.webp", "src": "display/9f8e7d6c5b4a.jpg" }
```

in album `2025-test` is fetched by the browser as

```
/media/events/2025-test/thumb/ab12cd34ef56.webp
/media/events/2025-test/display/9f8e7d6c5b4a.jpg
```

The prefix itself is defined once, as `MEDIA_BASE` in `web/assets/config.js`.
Change it there and you must change the `rewrite` in
`cache/nginx.conf.template` to match.

YouTube items are the one exception: their `src` and `thumb` are already
absolute `https://` URLs and are used verbatim, never prefixed with `/media/`.

---

## Browser smoke test

`curl` proves the server is right; it cannot prove the gallery *works*, because
the page is built by JavaScript. Run these five checks in a real browser after
any change to `web/`, after a lightGallery upgrade, and as the last step of a
server migration. They take about two minutes.

Use a published album — `2025-test` exists for exactly this purpose.

1. **Front-page grid renders.** Open `https://photos.libreminds.org/`. The album
   list is drawn by JavaScript from `albums/index.json`, so an empty page here
   means the JSON failed to load even though `curl` reported `200`. Each card
   should show a cover thumbnail, title, date and item count.

2. **Deep link, Esc and Back.** Open
   `https://photos.libreminds.org/album.html?a=2025-test#lg=2025-test&slide=1`
   directly in a fresh tab. The lightbox must open *immediately on the second
   item* — not on the first, and not closed. Then press **Esc** to close it, and
   press the browser **Back** button. This is the `lg-hash` plugin round-trip;
   if `galleryId` and the slug ever drift apart, the link silently opens slide 0.

3. **Video seeks.** In an album containing video, open the clip and drag the
   scrubber to the middle. Playback must resume quickly rather than re-buffering
   from the start. That is the `slice 1m` Range caching in
   `cache/nginx.conf.template` doing its job. Confirm with:
   `curl -sI -H 'Range: bytes=50000-60000' https://photos.libreminds.org/media/<key>`
   which must return `206` and an `x-cache` header.

4. **Mobile pinch-zoom and share.** On a phone (or device emulation), open an
   image, pinch to zoom, and open the share menu. These exercise the `lg-zoom`
   and `lg-share` plugins plus `mobileSettings` in `album.html`.

5. **No third-party requests.** Open DevTools → Network, reload the album page
   hard, and sort by domain. **Every** request must be to
   `photos.libreminds.org`. A request to `cdn.jsdelivr.net`, `unpkg.com` or
   `fonts.googleapis.com` means a vendored asset was lost — re-run
   `make vendor-lightgallery`. Verify from the shell too:

   ```bash
   curl -s "https://photos.libreminds.org/album.html?a=2025-test" \
     | grep -oE '(src|href)="[^"]*"' | grep -v '^\(src\|href\)="/' 
   ```
   The only match should be the lightGallery credit link in the footer, which is
   a hyperlink, not a resource load.

---

## Everyday commands

```
make check          validate compose + both nginx configs (starts nothing)
make up             start web + cache
make down           stop them
make logs           follow logs

make build          build the tools image
make publish SLUG=  publish an album
make publish-dry SLUG=
make index          rebuild web/albums/index.json

make backup         album metadata -> B2
make restore        B2 -> here    (make restore TARGET=.restore-check to verify)
make cache-stats    cache size and disk headroom
make cache-clear    empty the media cache (safe; refills from B2)
make migrate-check  can this project move to a new server today?
make shell          a shell in the tools container
```

Run `make` on its own for the same list.

---

## Setup on a fresh checkout

```bash
cp .env.example .env
chmod 600 .env
$EDITOR .env          # fill in B2_KEY_ID, B2_APP_KEY, B2_DOWNLOAD_HOST
make build
make check
make up
make migrate-check
```

Every variable is documented in `.env.example`. `make migrate-check` will tell
you if you missed one.

---

## Letting volunteers upload

The `tools` container runs as `PUID:PGID` from `.env`, never as root, so files
it writes into `web/albums/` and `inbox/` stay owned by a real account.
`make migrate-check` **fails** if either is unset or 0.

This server is already set up as follows — reproduce it on any new server
(it is also step 2b of MIGRATE.md):

```bash
# One-time, as root. This is the only thing this project creates outside
# /home/libre-media, and it is a single line in /etc/group.
groupadd -f mediateam
getent group mediateam            # note the gid; here it was 1002

# Owner = the account that runs make; group = the shared volunteer group.
chown -R 1000:1002 /home/libre-media/web/albums /home/libre-media/inbox

# 2775 = group-writable + setgid. setgid is the important half: everything
# created inside inherits `mediateam` instead of the creator's primary group,
# so the next volunteer can still write to it.
find /home/libre-media/web/albums /home/libre-media/inbox \
     -type d -exec chmod 2775 {} +

# Add each volunteer to the group (they must log out and back in):
usermod -aG mediateam <username>
```

Then in `.env`:

```
PUID=1000
PGID=1002
```

`cache-data/` is deliberately **not** included. The cache container chowns it to
its own unprivileged `nginx` user at every start, so any ownership set here
would be overwritten. It is disposable and never volunteer-facing.

Volunteers only ever need write access to `inbox/`. Publishing is still run by
someone with docker access.

---

## Cache and disk

`cache-data/` is a disposable nginx `proxy_cache`. Deleting it costs nothing but
a re-fetch from B2.

Two limits protect the rest of the server, both in `.env`:

- `CACHE_MAX_SIZE` — upper bound on the cache itself.
- `CACHE_MIN_FREE` — a hard floor on **filesystem** free space. nginx evicts
  cache entries rather than let the disk drop below this, whatever
  `CACHE_MAX_SIZE` says. This is the setting that stops a busy album from
  starving the other services on this host.

Check headroom with `make cache-stats` before raising either.

Video is fetched from B2 in 1 MB slices (`slice 1m`), each cached separately.
That is what makes seeking inside a long video both work and stay cached; without
it a mid-file seek would either bypass the cache or refetch the whole file.

---

## Why the bucket is public

The B2 bucket is public, so media is also reachable directly at
`https://<B2_DOWNLOAD_HOST>/file/<bucket>/events/...`, bypassing this site.
The `/media/` proxy is a performance and cost layer, not access control.

That is the right trade-off for a public event gallery — but it does mean **do
not put anything in `inbox/` that you would not publish**, and get consent
before uploading photos of identifiable people.

---

## Nightly backup

`make backup` copies `web/albums/*.json` and every `inbox/*/album.yaml` to
`b2:<bucket>/_site/`. It uses `rclone copy`, never `sync`, so it can add and
update but can never delete.

Install it as a **user** crontab for the account in `PUID`, not root:

```bash
# As that user (uid 1000 here):
crontab -e
```

```cron
# libre-media — nightly album metadata backup to Backblaze B2.
# The only entry this project needs outside /home/libre-media.
17 3 * * * cd /home/libre-media && /usr/bin/make backup >> /home/libre-media/backup.log 2>&1
```

The `cd` is not optional — cron runs with the user's home as the working
directory, and `make` must run inside the project. `03:17` rather than `03:00`
keeps it off the hour with everything else on this box. `backup.log` is
git-ignored.

**Prerequisite:** that user must be able to talk to the Docker daemon, because
`make backup` runs `rclone` inside the `tools` container:

```bash
usermod -aG docker <user>      # then the user must log out and back in
```

> **Understand what this grants.** Docker group membership is effectively root
> on this host — a member can start a container that mounts `/`. If you are not
> comfortable with that for the volunteer account, run the cron entry as root
> instead (`sudo crontab -e`, same line). The backup writes only to B2 and to
> `backup.log`, so running it as root is a defensible choice here; it just
> leaves `backup.log` root-owned.

Check it is working:

```bash
tail -20 /home/libre-media/backup.log
make restore TARGET=.restore-check && diff -r web/albums .restore-check/web/albums
```

---

## Licence

**Code** — this repository is **GPL-3.0-or-later** (`LICENSE`). It has to be
GPL-compatible because lightGallery v2 is vendored into it, also under GPLv3
(`web/assets/lightgallery/VERSION`) — which is exactly why no licence key is
needed. Source files carry an `SPDX-License-Identifier: GPL-3.0-or-later`
header.

**Media** — licensed **per album**, not by this repository. Each album declares
its own terms in the `license` field of its `album.yaml`, and that string is
copied into the album manifest and shown on the album page. **If an
`album.yaml` omits `license`, the album defaults to `CC BY-SA 4.0`.**

Set it explicitly whenever an album differs — a photographer who wants
attribution-only, an event that agreed to CC0, or material you are only
licensed to display:

```yaml
license: CC BY 4.0
```

The code licence and the media licence are independent: GPLv3 governs the
gallery software, the `album.yaml` field governs the photographs and video.
