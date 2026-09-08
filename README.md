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

> **Which half of this is yours?** If you are a **volunteer**, you do steps 1-3
> — copying files into `inbox/` over SFTP — and then tell an admin. Steps 4 and
> 5 need Docker access and are run by an **admin** as the service account. See
> "Access model" below.

```bash
cd /home/libre-media          # admins: publishing must run from here

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
  - kJQP7kiw5Fk          # the id from https://youtu.be/<id>, not the full URL
YAML

# 3. Drop the originals in. Any common format; they get converted for you.
cp ~/event-photos/*.jpg inbox/2025-kcd-bengaluru/photos/
cp ~/event-video/*.mov  inbox/2025-kcd-bengaluru/videos/

# 4. (admin) See what would happen. Changes nothing.
sudo -u libremedia make publish-dry SLUG=2025-kcd-bengaluru

# 5. (admin) Do it.
sudo -u libremedia make publish SLUG=2025-kcd-bengaluru
```

Everything must run as `libremedia`, the service account that owns these files.
Publishing as yourself or as root leaves files the service account cannot
replace on the next publish, and `make migrate-check` will start failing.

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
6. **Commits** `web/albums/` as `album: <slug>`. It does **not** push — run
   `sudo -u libremedia git push` afterwards, or `origin/main` drifts behind and
   a future server rebuilt by `git clone` would be missing recent albums.
   (`make backup` still mirrors the same JSON to B2 nightly, so nothing is
   actually lost — but the repo stops being an accurate second copy.)

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

Anything that writes files — `publish`, `index`, `restore`, `up` — should be run
as the service account: `sudo -u libremedia make <target>`, from
`/home/libre-media`. Read-only targets (`check`, `migrate-check`, `cache-stats`,
`logs`) are safe to run as yourself.

---

## Setup on a fresh checkout

Order matters: the service account has to exist before `.env` can name it.
For a full server move, follow MIGRATE.md instead — it covers this plus DNS.

```bash
# 1. As root: create the account that will own everything.
#    Pick a uid/gid free in BOTH passwd and group on this host.
groupadd --gid 1003 libremedia
useradd --system --uid 1003 --gid libremedia \
        --home-dir /home/libre-media --no-create-home --shell /bin/bash libremedia
passwd -l libremedia
usermod -aG docker libremedia          # needed to run the containers

# 2. As root: hand the tree over (cache-data/ is excluded on purpose --
#    the cache container chowns it to its own nginx uid at every start).
find /home/libre-media -path /home/libre-media/cache-data -prune -o -print0 \
  | xargs -0 chown -h libremedia:libremedia
find /home/libre-media/web/albums /home/libre-media/inbox -type d -exec chmod 2775 {} +

# 3. Configure.
cp .env.example .env
chmod 600 .env && chown libremedia:libremedia .env
$EDITOR .env    # B2_KEY_ID, B2_APP_KEY, B2_DOWNLOAD_HOST, and PUID/PGID = 1003

# 4. Everything from here runs as the service account.
sudo -u libremedia make build
sudo -u libremedia make check          # starts nothing
sudo -u libremedia make up
sudo -u libremedia make migrate-check  # must report 0 failed
```

Every variable is documented in `.env.example`, and `make migrate-check` names
any you missed. `B2_DOWNLOAD_HOST` is the one people get wrong — it must be the
`f00X.backblazeb2.com` friendly host, **not** the `s3.<region>` endpoint; the
symptom is `400 InvalidRequest` on every image while the pages load fine.

---

## Access model

Three roles, deliberately separated so a volunteer never needs Docker access
and day-to-day publishing never needs root. Root is still required twice:
once at setup, to create accounts and install the crontab entries, and
thereafter only to add or remove people.

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

Volunteers get a normal shell account by default. Locking them down to
SFTP-only is possible but is **not** configured here, and is not a loose end —
see MIGRATE.md "Known gaps" for why it conflicts with the group-writable
`inbox/` this setup relies on.

### Publishing (admin)

Publishing is run **as the service account** so files stay owned by it:

```bash
sudo -u libremedia make publish SLUG=2025-kcd-bengaluru
sudo -u libremedia make publish-dry SLUG=2025-kcd-bengaluru
```

A sudoers rule lets a named admin do this without knowing the service
account's business. **Installed on this server for `divya` only**, at
`/etc/sudoers.d/libre-media`:

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

## Importing from OneDrive (admin)

Event photos usually arrive in a shared OneDrive folder. `make import` pulls
them straight into `inbox/`, so nobody has to download a zip and re-upload it.

### The flow

```bash
cd /home/libre-media

# 1. Find the folder. Lists directories in the account.
sudo -u libremedia make onedrive-ls SRC="Photos"

# 2. See what would be downloaded. Changes nothing.
sudo -u libremedia make import-dry SLUG=2025-kcd-bengaluru SRC="Photos/KCD Bengaluru 2025"

# 3. Download for real. Images -> inbox/<slug>/photos/, video -> videos/.
sudo -u libremedia make import SLUG=2025-kcd-bengaluru SRC="Photos/KCD Bengaluru 2025"

# 4. Edit the album.yaml it created. The date is a placeholder and publishing
#    WILL FAIL until you replace it with the real event date.
$EDITOR inbox/2025-kcd-bengaluru/album.yaml

# 5. Publish as normal.
sudo -u libremedia make publish SLUG=2025-kcd-bengaluru
```

Import takes `.jpg .jpeg .png .heic .mp4 .mov`, case-insensitively, so `.JPG`
and `.HEIC` straight off a phone are picked up. iPhone HEIC originals are
converted by the build step like any other format. Anything else in the folder
— `.txt`, `.zip`, RAW files, `Thumbs.db` — is ignored.

It uses `rclone copy` **only**. There is no `sync`, `move` or `purge` anywhere
in this pipeline, so a wrong `SRC` costs you a wasted download and nothing
else. Files already present at the same size are skipped, so re-running an
interrupted import resumes rather than starting over.

If `album.yaml` already exists it is left alone; import never overwrites your
metadata.

### Long imports

A large event is gigabytes and takes many minutes. Run it detached so a dropped
SSH connection cannot kill it half way:

```bash
sudo -u libremedia tmux new-session -d -s kcdimport \
  'make import SLUG=2024-kcd-kerala SRC=kcd_upload \
     > inbox/2024-kcd-kerala/import.log 2>&1'

sudo -u libremedia tmux attach -t kcdimport      # Ctrl-B then D to detach
tail -f inbox/2024-kcd-kerala/import.log
```

rclone reports progress every 30 seconds as a labelled block, so the log stays
readable and greppable:

```
Transferred:        4.512 GiB / 9.100 GiB, 50%, 12.345 MiB/s, ETA 6m20s
Checks:               866 / 866, 100%
Elapsed time:       6m12.0s
```

Transfers pause occasionally — OneDrive throttles a long burst and rclone backs
off quietly. A frozen byte count with a falling rate and a climbing ETA is that
backoff, not a hang; it clears itself. Look for `Errors:` in the log before
concluding anything is wrong.

When it finishes, verify against the source rather than trusting the transfer:

```bash
sudo -u libremedia docker compose --profile tools run --rm -T tools -lc \
  'rclone check "onedrive:kcd_upload" inbox/2024-kcd-kerala/photos --size-only --one-way'
# want: 0 differences found
```

### Share links do not work

**A OneDrive share link is not a path and rclone cannot use one.** The
`1drv.ms/...` and `...sharepoint.com/:f:/...` URLs on libreminds.org are
browser links; they carry no credential rclone can present and are not part of
the account's own filesystem. `SRC` must be the folder's path **inside the
account whose token you configured**, exactly as `make onedrive-ls` shows it:

```
SRC="Photos/KCD Bengaluru 2025"        correct
SRC="https://1drv.ms/f/s!AbCdEf"       rejected, with this explanation
```

If the photos live in someone else's OneDrive, they must either add the folder
to the gallery account's own drive ("Add shortcut to My files" in the OneDrive
web UI, which then appears as a normal path), or share the files another way.

### One-time token setup

rclone needs an OAuth token. Authorising requires a browser, so it is done on
a laptop and the result pasted in here — the server never opens a browser and
never sees your password.

**On your laptop**, with rclone installed:

```bash
rclone authorize "onedrive"
```

A browser window opens, you sign in to the gallery's Microsoft account and
approve access. rclone then prints a token blob to the terminal:

```
Paste the following into your remote machine --->
{"access_token":"...","token_type":"Bearer","refresh_token":"...","expiry":"..."}
<---End paste
```

**On the server**, put it in `/home/libre-media/.config/rclone/rclone.conf`:

```ini
[onedrive]
type = onedrive
token = {"access_token":"...","token_type":"Bearer","refresh_token":"...","expiry":"..."}
drive_type = business
drive_id = b!xxxxxxxxxxxxxxxxxxxx
```

`token` must be the whole blob on **one line**. Then:

```bash
chmod 600 /home/libre-media/.config/rclone/rclone.conf
chown libremedia:libremedia /home/libre-media/.config/rclone/rclone.conf
sudo -u libremedia make onedrive-ls          # should list folders
sudo -u libremedia make migrate-check        # checks the file's permissions
```

If you do not know `drive_id` and `drive_type`, add just `type` and `token`
first, then ask the API:

```bash
sudo -u libremedia docker compose --profile tools run --rm -T tools \
  -lc 'rclone backend drives onedrive:'
```

Copy the id and type of the drive you want into the config. A personal account
uses `drive_type = personal`; a Microsoft 365 / work account uses `business`.

### Why this file exists at all

B2 credentials are passed as environment variables so they never touch disk
(CLAUDE.md §5). OneDrive cannot work that way: OAuth tokens expire, and rclone
refreshes them and **writes the new one back**. That needs a persistent,
writable file. So `.config/rclone/rclone.conf` holds the OneDrive remote and
nothing else — B2 is still environment-only.

Treat that file exactly like `.env`: **0600, owned by `libremedia`,
git-ignored**. `make migrate-check` fails if the permissions or ownership are
wrong, and fails loudly if it ever appears in git. It is not in the repository
and must be copied by hand to a new server — see MIGRATE.md.

---

## Taking content down

Someone withdraws consent, a photo turns out to be of a minor, a copyright
claim arrives. Three targets, smallest blast radius first.

**Every one requires `DRY=1` first.** The real run refuses unless a dry run for
that exact slug (and item) happened within the last ten minutes, prints the
object count, and makes you type the slug at a terminal. It also refuses if the
working tree is dirty, because it commits.

Nothing here uses `rclone purge` or `rclone sync` — objects are listed first and
deleted from that explicit list, so a prefix typo cannot take out a neighbouring
album and there is always a listing to audit against.

### One photo or video

```bash
# ID is the item's "id" in web/albums/<slug>.json -- also its filename.
sudo -u libremedia make unpublish-photo SLUG=2024-kcd-kerala ID=d071f27934e3 DRY=1
sudo -u libremedia make unpublish-photo SLUG=2024-kcd-kerala ID=d071f27934e3
```

Deletes its thumbnail, display image and (for video) poster and MP4 from B2,
removes it from the album manifest, **deletes the local original from
`inbox/`**, prunes it from the build cache, rebuilds the index, mirrors,
commits, pushes, and purges it from the cache.

Deleting the local original is not optional. Leave it and the next
`make publish` rebuilds the photo, re-uploads it, and puts it back — a takedown
that silently undoes itself.

### A whole album

```bash
sudo -u libremedia make unpublish SLUG=2024-kcd-kerala DRY=1
sudo -u libremedia make unpublish SLUG=2024-kcd-kerala
```

Same, for everything: all `events/<slug>/` objects, the mirrored album JSON, the
backed-up `album.yaml`, `web/albums/<slug>.json`, and `inbox/<slug>/`.

### Just evict from the cache

```bash
sudo -u libremedia make cache-purge PREFIX=events/2024-kcd-kerala
sudo -u libremedia make cache-purge PREFIX=events/2024-kcd-kerala/display/ab12cd34ef56.jpg
sudo -u libremedia make cache-purge PREFIX=events/2024-kcd-kerala DRY=1
```

The other two call this for you. Use it directly if you deleted something from
B2 by hand.

> The cache key is **not** the URL you see in a browser.
> `cache/nginx.conf.template` rewrites `/media/<path>` to
> `/file/<bucket>/<path>` *before* `proxy_cache_key` is evaluated, so nginx
> stores `KEY: /file/libreminds-media/events/…`. `PREFIX` is given in
> browser terms and translated for you. This matters if you ever purge by
> hand: matching the wrong form finds nothing and looks exactly like success,
> which is why the target always prints a count.

### What "taken down" actually means

Be precise with whoever asked, because three different caches are involved.

| Where | When it stops being available |
|---|---|
| **This site** | Immediately, once `cache-purge` has run. Until then the local cache serves it for up to `CACHE_INACTIVE` (30 days) even though B2 no longer has it. |
| **A direct B2 URL** | Only when the B2 delete happens. The bucket is public, so anyone who saved `https://<b2-host>/file/<bucket>/events/…` keeps access until then. |
| **A browser that already loaded it** | Up to **a year**. Media is served `Cache-Control: public, max-age=31536000, immutable`, and we cannot reach into someone's browser. |

So: you can promise the image is off the site and off B2 within minutes. You
cannot promise it has vanished from every device that already showed it, and
you should not imply otherwise. If someone already downloaded or screenshotted
it, nothing technical here helps at all.

If the request is urgent and you want it off the site *now*, before working out
which item it is, `make cache-clear` empties the whole cache — but that only
helps if the object is also gone from B2, since the next request re-fetches it.

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
