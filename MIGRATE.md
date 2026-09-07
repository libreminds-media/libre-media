# Moving libre-media to a new server

The whole project is one directory and one B2 bucket. There is nothing to move
except this repository and `.env` — media bytes already live in B2, and
`cache-data/` is disposable.

**Time required:** about 20 minutes, of which 15 is waiting for DNS.
**Downtime:** none, if you follow the order below. The old server keeps serving
until you cut DNS over, and you verify the new one *before* you do.

---

## What actually has to move

| Thing | Where it lives | How it moves |
|---|---|---|
| Site code, pages, vendored lightGallery | this git repo | `git clone` |
| Album metadata (`web/albums/*.json`) | this git repo **and** `b2:<bucket>/_site/albums/` | `git clone`, or `make restore` |
| Volunteer `album.yaml` files | `b2:<bucket>/_site/inbox/` | `make restore` |
| Media bytes (photos, video) | `b2:<bucket>/events/` | nothing to do — B2 is the source of truth |
| Secrets and host config | `.env` | copy by hand, out of band |
| Cache | `cache-data/` | nothing to do — it refills itself |

If the old server is already gone, `make restore` rebuilds `web/albums/` and the
`album.yaml` files from B2. You lose nothing but the raw originals in `inbox/`,
which were never on the server's critical path.

---

## Prerequisites on the new server

1. Docker Engine with the Compose plugin (`docker compose version` must work).
2. A running **caddy-docker-proxy** with automatic TLS, and the name of the
   docker network it watches:
   ```bash
   docker inspect <your-caddy-container> \
     --format '{{range .Config.Env}}{{println .}}{{end}}' | grep INGRESS
   # CADDY_INGRESS_NETWORKS=caddy   <- this value goes in CADDY_NETWORK
   ```
3. Ports 80 and 443 reachable from the internet (Caddy needs them for ACME).
4. Enough disk for the media cache — see `CACHE_MAX_SIZE` and `CACHE_MIN_FREE`.
5. A group for the volunteer uid/gid, matching `PUID`/`PGID` in `.env`. This is
   the **only** thing this project needs outside `/home/libre-media`, and it is
   one line in `/etc/group`. See step 2b.

Nothing else. No Python, no ffmpeg, no rclone on the host.

---

## The move

### 1. Clone

```bash
git clone <repo-url> /home/libre-media
cd /home/libre-media
```

The path matters: `docker-compose.yml` uses relative bind mounts, so any path
works, but keep everything under one directory as CLAUDE.md requires.

### 2. Bring `.env` across

Copy it from the old server by hand — it is git-ignored on purpose and contains
the B2 application key.

```bash
# On the OLD server:
cat /home/libre-media/.env          # copy the output somewhere safe

# On the NEW server:
$EDITOR /home/libre-media/.env      # paste, then:
chmod 600 .env
```

Then update the two host-specific values if they changed:

- `CADDY_NETWORK` — the network from the prerequisites step.
- `CACHE_MAX_SIZE` / `CACHE_MIN_FREE` — size for the new disk, not the old one.

`SITE_HOST`, `B2_*` and the rest carry over unchanged.

### 2b. Recreate the volunteer group and ownership

`PUID`/`PGID` in `.env` refer to a uid and gid that must exist on the **new**
server, and the directories they own must be writable by them. `make
migrate-check` fails if `PUID`/`PGID` are unset or 0.

```bash
groupadd -f mediateam
getent group mediateam        # if the gid differs from the old server,
                              # update PGID in .env to match

chown -R $(grep -E '^PUID=' .env | cut -d= -f2):$(grep -E '^PGID=' .env | cut -d= -f2) \
      web/albums inbox
find web/albums inbox -type d -exec chmod 2775 {} +

usermod -aG mediateam <each volunteer>
```

Do **not** chown `cache-data/` — the cache container manages it.

### 3. Build and restore

```bash
make build            # builds the tools image
make restore          # pulls album metadata + album.yaml files out of B2
```

`make restore DRY=1` first if you want to see what it would fetch.

If you cloned the repo, `web/albums/` is already correct and `make restore` is a
no-op that also brings back the `album.yaml` files. Run it anyway — it is cheap
and it proves your B2 credentials work.

### 4. Validate before starting anything

```bash
make check            # docker compose config + nginx -t on both configs
make migrate-check    # 30-odd checks; everything must be PASS
```

`make check` starts no containers. `make migrate-check` will WARN that
`SITE_HOST` still resolves to the **old** server — that is correct at this
point and is exactly what you want to see.

### 5. Start it

```bash
make up
```

`make up` runs `make check` first, then tails the caddy-docker-proxy log for 15
seconds so a bad label shows up immediately. **Read that output.** If
caddy-docker-proxy reports a config error, run `make down` at once — a malformed
label can affect config generation for every other site on that proxy.

Caddy will try to issue a certificate for `SITE_HOST` and **fail**, because DNS
still points at the old server. That is expected and harmless; it retries.

### 6. Verify BEFORE touching DNS

This is the whole point of the ordering. Test the new server by overriding DNS
locally with `curl --resolve`, so nothing about the live site changes.

```bash
NEW_IP=<new server public ip>
HOST=$(grep -E '^SITE_HOST=' .env | cut -d= -f2-)

# Containers healthy?
docker compose ps
curl -s http://localhost/healthz          # only if you temporarily publish a port

# Front page, resolved to the NEW box. Expect: HTTP/2 200
curl -sI --resolve "$HOST:443:$NEW_IP" "https://$HOST/" | head -5

# TLS certificate — Caddy cannot get a real one until DNS moves, so this WILL
# show a self-signed/internal cert or a TLS error at this stage. Prove the
# origin instead by skipping verification:
curl -skI --resolve "$HOST:443:$NEW_IP" "https://$HOST/" | head -5

# Album list is real JSON, not an error page
curl -sk --resolve "$HOST:443:$NEW_IP" "https://$HOST/albums/index.json" | head -20

# Media proxy works and caches. First request MISS, second HIT.
SLUG=$(curl -sk --resolve "$HOST:443:$NEW_IP" "https://$HOST/albums/index.json" \
       | python3 -c 'import json,sys;print(json.load(sys.stdin)["albums"][0]["slug"])')
IMG=$(curl -sk --resolve "$HOST:443:$NEW_IP" "https://$HOST/albums/$SLUG.json" \
       | python3 -c 'import json,sys;m=json.load(sys.stdin);print(m["base"]+m["items"][0]["src"])')

curl -skI --resolve "$HOST:443:$NEW_IP" "https://$HOST/media/$IMG" | grep -iE 'HTTP|x-cache'
curl -skI --resolve "$HOST:443:$NEW_IP" "https://$HOST/media/$IMG" | grep -iE 'HTTP|x-cache'
# Expect: 200 + X-Cache: MISS, then 200 + X-Cache: HIT

# Range requests (video seeking) work
curl -skI -H 'Range: bytes=0-1023' --resolve "$HOST:443:$NEW_IP" \
     "https://$HOST/media/$IMG" | grep -iE 'HTTP|content-range'
# Expect: 206 Partial Content
```

Open `https://$HOST/` in a browser with a hosts-file override if you want a
visual check. **Do not proceed until every one of these passes.**

### 7. Cut DNS over

Lower the TTL on the A record to 300s a few hours ahead if you can. Then point
`SITE_HOST` at the new IP.

```bash
# Watch it propagate:
dig +short @1.1.1.1 photos.libreminds.org A
```

Once it returns the new IP, Caddy issues a real certificate within a minute or
two. Confirm:

```bash
curl -sI "https://$HOST/" | head -5           # no -k this time; must be clean
curl -sI "https://$HOST/media/$IMG" | grep -i x-cache
make migrate-check                            # the DNS warning should now be PASS
```

### 8. Nightly backup

Add the one permitted crontab line (the only thing this project puts outside
`/home/libre-media`):

```cron
17 3 * * * /usr/bin/make backup >> /home/libre-media/backup.log 2>&1
```

### 9. Decommission the old server

Only after the new one has served real traffic for a day:

```bash
# On the OLD server:
cd /home/libre-media && make down
```

Leave the directory in place for a week before deleting it. **Do not touch the
B2 bucket** — it is now the new server's source of truth.

---

## Rollback

DNS back to the old IP. The old server was never modified, and both servers can
read the same B2 bucket at the same time without conflict, because media is
immutable and `rclone copy` never deletes.

---

## Verification checklist

| Check | Command | Expected |
|---|---|---|
| Config valid | `make check` | compose OK, `syntax is ok` twice |
| Migration readiness | `make migrate-check` | 0 failed |
| Containers up | `docker compose ps` | `web` and `cache` healthy |
| Caddy accepted our labels | `docker logs --since 5m caddy-proxy` | no config errors |
| Front page | `curl -sI https://$HOST/` | `200`, `cache-control: public, max-age=300` |
| Album JSON | `curl -s https://$HOST/albums/index.json` | valid JSON |
| Media proxy | `curl -sI https://$HOST/media/<key>` | `200`, `x-cache: MISS` then `HIT` |
| Media immutability header | same | `cache-control: ..., immutable` |
| Video seeking | `curl -sI -H 'Range: bytes=0-1023' ...` | `206 Partial Content` |
| Deep link | open `https://$HOST/album.html?a=<slug>#lg=<slug>&slide=2` | opens on slide 3 |
| Backup round-trip | `make backup && make restore TARGET=.restore-check` | `diff -r` clean |
| No secrets committed | `git grep -i -E 'key\|secret' -- ':!*.example'` | nothing |

---

## Known gaps

Things deliberately left undone, so the next person is not surprised:

- **`LG_LICENSE_KEY` in `.env` is not wired up.** lightGallery is vendored under
  GPLv3 and this repo is public under a compatible licence, so no key is needed
  and the GPL placeholder in `web/assets/config.js` is correct. If you ever buy
  a commercial licence, `web/` is served as plain static files with no
  templating, so the key would have to be edited into `web/assets/config.js` by
  hand — or `web/` would need a render step at container start like the nginx
  configs have.
- **No image-level access control.** The B2 bucket is public; `/media/` is a
  cache, not a gate. See "Why the bucket is public" in README.md.
- **`inbox/` originals are not backed up** — only `album.yaml`. The originals
  are volunteers' own copies; the published derivatives in B2 are what matters.
- **`docker builder prune` is not automated.** Docker build cache grows on this
  class of host and is the usual cause of a full disk. Check `docker system df`
  when `make cache-stats` shows the filesystem tightening.
