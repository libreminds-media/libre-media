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

## Access model

Three roles, deliberately separated so a volunteer never needs docker access
and no one needs root.

| Role | Account | Can do | Cannot do |
|---|---|---|---|
| **Service** | `libremedia` (uid/gid 1003) | owns every file; runs the containers | log in with a password (locked) |
| **Volunteer** | their own account, in group `libremedia` | SFTP files into `inbox/` | publish, touch containers, read `.env` |
| **Admin** | their own account + one sudoers rule | run `publish` as `libremedia` | nothing else via that rule |

`libremedia` is a dedicated service account. Its home **is** `/home/libre-media`,
its password is locked, and it is in the `docker` group. `PUID`/`PGID` in `.env`
must be its uid/gid — `make migrate-check` fails if they do not match the owner
of `web/albums/` and `inbox/`.

> Because the service account's home is the repository, anything it writes to
> its home lands inside the repo. `.gitignore` therefore excludes `.ssh/`,
> `.bash_history`, `.cache/` and friends. **Do not remove those lines** —
> `.ssh/` holds the deploy key.

### Adding a volunteer

Volunteers get a personal account added to the `libremedia` group, and SFTP
access to `inbox/` only. They never get docker access and never run `publish`.

```bash
# As root, once per volunteer:
adduser --disabled-password --gecos "" alice
usermod -aG libremedia alice          # they must log out and back in

# They upload over SFTP to:
#   /home/libre-media/inbox/<year>-<event-name>/{album.yaml,photos/,videos/}
```

`inbox/` and `web/albums/` are `2775` (group-writable + **setgid**). setgid is
the important half: everything created inside inherits group `libremedia`
rather than the creator's primary group, so the next volunteer can still write
to it.

To restrict a volunteer to SFTP with no shell, add to `/etc/ssh/sshd_config`:

```
Match Group libremedia
    ChrootDirectory /home/libre-media/inbox
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
```

> `ChrootDirectory` requires the chroot target to be owned by **root** and not
> group-writable, which conflicts with the `2775 libremedia:libremedia` that
> volunteers need. Either drop `ChrootDirectory` and rely on group permissions,
> or restructure with a root-owned parent. Decide before enabling this — it is
> not currently configured.

### Publishing (admin)

Publishing is run **as the service account** so files stay owned by it:

```bash
sudo -u libremedia make publish SLUG=2025-kcd-bengaluru
sudo -u libremedia make publish-dry SLUG=2025-kcd-bengaluru
```

To let a named admin do exactly that and nothing more, install this with
`visudo -f /etc/sudoers.d/libre-media` (mode `0440`). **This is documentation;
it is not installed on this server.**

```sudoers
# /etc/sudoers.d/libre-media
# Let named admins run the gallery's publish commands as the service account.
#
# Scope note: `make` is a general-purpose program. This rule constrains the
# TARGET but a determined user could still reach other make targets, and
# `libremedia` is in the `docker` group, which is root-equivalent on this host.
# Grant it only to people you would trust with root anyway.

Cmnd_Alias LIBREMEDIA_PUBLISH = \
    /usr/bin/make publish SLUG=*, \
    /usr/bin/make publish-dry SLUG=*, \
    /usr/bin/make index, \
    /usr/bin/make backup, \
    /usr/bin/make migrate-check

%libremedia-admin ALL=(libremedia) NOPASSWD: LIBREMEDIA_PUBLISH
```

```bash
groupadd -f libremedia-admin
usermod -aG libremedia-admin alice
```

Note that `sudo -u libremedia make ...` runs make in the *caller's* working
directory, so admins must `cd /home/libre-media` first.

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

## Scheduled jobs

Two entries in **root's** crontab (`sudo crontab -e`). They are the only things
this project puts outside `/home/libre-media`.

```cron
# --- libre-media (photos.libreminds.org) -----------------------------------
# Nightly: album metadata -> Backblaze B2. Uses `rclone copy`, never `sync`,
# so it can add and update but can never delete.
# The `cd` is required: cron starts in the user's home, and make must run
# inside the project directory.
17 3 * * * cd /home/libre-media && /usr/bin/make backup >> /home/libre-media/backup.log 2>&1
#
# Monthly (1st, 04:23): reclaim Docker build cache. This is the usual cause of
# a full disk on this host -- it was 53GB at project setup. Build cache only:
# no image, container or volume is touched.
23 4 1 * * cd /home/libre-media && /usr/bin/docker builder prune -f >> /home/libre-media/prune.log 2>&1
```

**Why root and not `libremedia`?** Both jobs need the Docker daemon. Running
them from root's crontab avoids nothing — root already has that access — while
running them as `libremedia` would add no isolation, since docker group
membership is root-equivalent anyway. The backup writes only to B2 and to
`backup.log`, and it creates no root-owned files in the project: verified by
running the exact line from `/root` with an empty environment.

`backup.log` and `prune.log` are git-ignored and are pre-created owned by
`libremedia`, so a root-run job appends rather than taking them over.

### Checking the jobs work

```bash
tail -20 /home/libre-media/backup.log
sudo -u libremedia make restore TARGET=.restore-check
diff -r /home/libre-media/web/albums /home/libre-media/.restore-check/web/albums
rm -rf /home/libre-media/.restore-check
```

Neither log rotates. They grow a few lines a night; revisit in a year.

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
