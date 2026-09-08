#!/usr/bin/env bash
#
# Pre-flight for "could this project move to a new server today?"
#
#   make migrate-check
#
# Every check maps to a step in MIGRATE.md. A FAIL means the move would break;
# a WARN means it would work but you should know about it.

set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

head_ "Configuration"

if [ -f .env ]; then
  ok ".env exists"
  mode="$(stat -c '%a' .env)"
  if [ "$mode" = "600" ]; then
    ok ".env is chmod 600"
  else
    bad ".env is chmod $mode, must be 600 -- run: chmod 600 .env"
  fi
else
  bad ".env missing -- cp .env.example .env && chmod 600 .env"
fi

if [ -f .env ] && [ -f .env.example ]; then
  missing=""
  empty=""
  while IFS= read -r var; do
    if ! grep -qE "^${var}=" .env; then
      missing="${missing} ${var}"
    elif [ -z "$(grep -E "^${var}=" .env | head -1 | cut -d= -f2-)" ]; then
      # LG_LICENSE_KEY is documented as intentionally empty (GPLv3 path).
      [ "$var" = "LG_LICENSE_KEY" ] || empty="${empty} ${var}"
    fi
  done < <(grep -oE '^[A-Z][A-Z0-9_]*=' .env.example | tr -d '=')

  [ -z "$missing" ] && ok "every .env.example variable is present in .env" \
                    || bad "missing from .env:${missing}"
  [ -z "$empty" ]   && ok "no required .env variable is blank" \
                    || bad "blank in .env:${empty}"
fi

# The tools container writes into web/albums/ and inbox/. Running it as root
# leaves root-owned files that volunteers cannot replace over SFTP.
if [ -f .env ]; then
  puid="$(grep -E '^PUID=' .env | head -1 | cut -d= -f2-)"
  pgid="$(grep -E '^PGID=' .env | head -1 | cut -d= -f2-)"
  if [ -z "$puid" ] || [ -z "$pgid" ]; then
    bad "PUID/PGID are not set in .env (found PUID='${puid}' PGID='${pgid}').
        Uncomment and set them to a NON-ROOT account that owns
        web/albums/ and inbox/ -- see README 'Letting volunteers upload'."
  elif [ "$puid" = "0" ] || [ "$pgid" = "0" ]; then
    bad "PUID/PGID resolve to root (PUID=$puid PGID=$pgid).
        The tools container must not run as root -- it would write root-owned
        files into web/albums/ and inbox/. Set them to a real account."
  else
    # They must also match the account that actually owns the directories the
    # tools container writes to, or publishing produces files the service
    # account cannot replace next time.
    ouid="$(stat -c '%u' web/albums)"
    ogid="$(stat -c '%g' web/albums)"
    if [ "$puid" = "$ouid" ] && [ "$pgid" = "$ogid" ]; then
      ok "PUID/PGID ($puid:$pgid = $(stat -c '%U:%G' web/albums)) match the owner of web/albums and inbox"
    else
      bad "PUID/PGID ($puid:$pgid) do not match the owner of web/albums ($ouid:$ogid = $(stat -c '%U:%G' web/albums)).
        The tools container would write files the owning account cannot replace.
        Fix .env, or: chown -R $puid:$pgid web/albums inbox"
    fi
  fi
fi

head_ "Files needed for a clean clone"

for f in docker-compose.yml Makefile README.md MIGRATE.md .env.example .gitignore \
         cache/nginx.conf.template cache/05-cache-perms.sh \
         webconf/default.conf.template tools/Dockerfile \
         pipeline/build_album.py pipeline/update_index.py \
         pipeline/manifest_changed.py pipeline/import.sh \
         pipeline/cache_purge.sh pipeline/unpublish.sh \
         pipeline/unpublish_photo.sh pipeline/remove_item.py \
         pipeline/publish.sh pipeline/backup.sh pipeline/restore.sh \
         web/index.html web/album.html web/assets/style.css \
         web/assets/config.js web/assets/media.js LICENSE \
         web/assets/lightgallery/lightgallery.umd.js \
         web/assets/lightgallery/css/lightgallery-bundle.css; do
  [ -e "$f" ] && ok "$f" || bad "$f is missing"
done

lgplugins=$(find web/assets/lightgallery/plugins -name '*.umd.js' 2>/dev/null | wc -l)
[ "$lgplugins" -ge 6 ] && ok "lightGallery plugins vendored ($lgplugins)" \
                       || bad "expected 6 vendored lightGallery plugins, found $lgplugins"

head_ "Compose + docker"

if docker compose config -q 2>/tmp/mc.$$; then
  ok "docker compose config parses"
else
  bad "docker compose config failed: $(head -2 /tmp/mc.$$ | tr '\n' ' ')"
fi
rm -f /tmp/mc.$$

if [ -f .env ]; then
  net="$(grep -E '^CADDY_NETWORK=' .env | cut -d= -f2-)"
  if [ -n "$net" ] && docker network inspect "$net" >/dev/null 2>&1; then
    ok "external caddy network '$net' exists"
  else
    bad "external caddy network '${net:-<unset>}' not found -- create it or fix CADDY_NETWORK"
  fi
fi

if docker image inspect libre-media-tools:latest >/dev/null 2>&1; then
  ok "tools image built"
else
  warn "tools image not built yet -- run: make build"
fi

head_ "Site state"

if [ -f web/albums/index.json ]; then
  if python3 -c "import json;json.load(open('web/albums/index.json'))" 2>/dev/null; then
    n=$(python3 -c "import json;print(len(json.load(open('web/albums/index.json'))['albums']))")
    ok "web/albums/index.json parses ($n album(s))"
  else
    bad "web/albums/index.json is not valid JSON"
  fi
else
  bad "web/albums/index.json missing -- run: make index"
fi

badjson=""
for f in web/albums/*.json; do
  [ -e "$f" ] || continue
  python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$f" 2>/dev/null || badjson="$badjson $f"
done
[ -z "$badjson" ] && ok "all album JSON parses" || bad "malformed:$badjson"

head_ "Secrets hygiene"

# Two checks, in increasing order of strength.
#
# 1. Look for an assigned LITERAL that looks like a credential. Matching the
#    bare word "key" or "secret" is useless here -- this project necessarily
#    talks about keys in prose and refers to ${B2_APP_KEY} in compose -- so
#    require an = or : followed by a 16+ char literal that is NOT a ${VAR}
#    reference and not an obvious placeholder.
if git grep -I -i -n -E \
     '(api|app|secret|access|private|auth)[-_]?(key|token|secret)[[:space:]]*[=:][[:space:]]*"?[A-Za-z0-9/+_-]{16,}' \
     -- ':!*.example' ':!*.md' >/tmp/sec.$$ 2>/dev/null \
   && grep -vE '\$\{|<[a-z]|PLACEHOLDER|xxxx|your[-_]' /tmp/sec.$$ | grep -q .; then
  bad "an assigned credential-looking literal is in a tracked file:"
  grep -vE '\$\{|<[a-z]|PLACEHOLDER|xxxx|your[-_]' /tmp/sec.$$ | sed 's/^/        /' | head -5
else
  ok "no assigned credential literals in tracked files"
fi
rm -f /tmp/sec.$$

# 2. The decisive check: take the ACTUAL values out of .env and prove they
#    appear nowhere in the tracked tree or in git history. This is what
#    actually matters before making the repo public.
if [ -f .env ]; then
  leaked=""
  for var in B2_APP_KEY B2_KEY_ID LG_LICENSE_KEY; do
    val="$(grep -E "^${var}=" .env | head -1 | cut -d= -f2-)"
    [ -n "$val" ] || continue
    [ "${#val}" -ge 8 ] || continue
    if git grep -q -F -- "$val" 2>/dev/null; then
      leaked="${leaked} ${var}(tracked-file)"
    fi
    if git log -p --all 2>/dev/null | grep -q -F -- "$val"; then
      leaked="${leaked} ${var}(git-history)"
    fi
  done
  if [ -z "$leaked" ]; then
    ok "no .env value appears in any tracked file or anywhere in git history"
  else
    bad "SECRET LEAKED:${leaked} -- do not publish this repository"
  fi
fi

# The OneDrive OAuth refresh token is a credential like any other. It lives in
# a file (rclone has to write refreshed tokens back), so it needs the same
# treatment as .env: 0600, owned by the service account, never tracked.
RCONF=".config/rclone/rclone.conf"
if [ -f "$RCONF" ]; then
  rperm="$(stat -c '%a' "$RCONF")"
  rown="$(stat -c '%U:%G' "$RCONF")"
  oexp="$(stat -c '%U:%G' web/albums)"
  if [ "$rperm" != "600" ]; then
    bad "$RCONF is mode $rperm, must be 600 -- it holds the OneDrive OAuth
        refresh token. Fix with: chmod 600 $RCONF"
  elif [ "$rown" != "$oexp" ]; then
    bad "$RCONF is owned by $rown, expected $oexp (the service account).
        Fix with: chown $oexp $RCONF"
  else
    ok "$RCONF is 0600 and owned by $rown"
  fi
  if git check-ignore -q "$RCONF"; then
    ok "$RCONF is git-ignored"
  else
    bad "$RCONF is NOT git-ignored -- it would be published with the repo"
  fi
  if git ls-files --error-unmatch "$RCONF" >/dev/null 2>&1; then
    bad "$RCONF is TRACKED IN GIT -- revoke the OneDrive token and purge it"
  fi
  if grep -q '^\[onedrive\]' "$RCONF" 2>/dev/null; then
    # An UNCOMMENTED token assignment. Matching the bare word would also match
    # the commented placeholder in the skeleton config, which is exactly the
    # false pass this check exists to avoid.
    if grep -qE '^[[:space:]]*token[[:space:]]*=' "$RCONF"; then
      ok "onedrive remote is configured with a token"
    else
      warn "$RCONF has an [onedrive] stanza but no token -- run the one-time
        setup in README \"Importing from OneDrive\""
    fi
  fi
else
  warn "$RCONF not present -- OneDrive import is unavailable (everything else
        works). See README \"Importing from OneDrive\"."
fi

if git check-ignore -q .env; then ok ".env is git-ignored"; else bad ".env is NOT git-ignored"; fi
if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  bad ".env is TRACKED IN GIT -- remove it from history before pushing"
else
  ok ".env is not tracked"
fi

head_ "Portability"

if git remote -v | grep -q .; then
  ok "git remote configured ($(git remote | head -1)) -- a new server can clone"
else
  warn "no git remote -- a new server would need the repo copied by hand"
fi

if [ -f .env ]; then
  host="$(grep -E '^SITE_HOST=' .env | cut -d= -f2-)"
  resolved="$( (command -v dig >/dev/null && dig +short @1.1.1.1 "$host" A 2>/dev/null) \
               || curl -s -m 8 -H 'accept: application/dns-json' \
                    "https://cloudflare-dns.com/dns-query?name=${host}&type=A" \
                  | python3 -c 'import json,sys;d=json.load(sys.stdin);print("\n".join(a["data"] for a in d.get("Answer",[]) if a.get("type")==1))' 2>/dev/null )"
  mine="$(curl -s -m 8 https://api.ipify.org 2>/dev/null)"
  if [ -z "$resolved" ]; then
    warn "$host does not resolve -- Caddy cannot get a TLS certificate yet"
  elif [ "$resolved" = "$mine" ]; then
    ok "$host resolves to this host ($mine)"
  else
    warn "$host resolves to $resolved but this host is $mine (fine mid-migration)"
  fi
fi

head_ "Result"
printf '  %d passed, %d warnings, %d failed\n\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]
