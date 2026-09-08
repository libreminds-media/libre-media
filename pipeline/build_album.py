#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Turn inbox/<slug>/ into upload-ready derivatives + a manifest.

    inbox/<slug>/album.yaml        metadata
    inbox/<slug>/photos/*          source stills
    inbox/<slug>/videos/*          source video

becomes

    inbox/<slug>/_build/thumb/<hash>.webp     400px  grid thumbnails
    inbox/<slug>/_build/display/<hash>.jpg   1920px  lightbox images
    inbox/<slug>/_build/video/<hash>.mp4     1920px  h264 + faststart
    inbox/<slug>/_build/video/<hash>.jpg             poster frames
    inbox/<slug>/_build/manifest.json                installed as web/albums/<slug>.json

Filenames are the first 12 hex of the sha256 of the OUTPUT bytes, so media is
immutable (CLAUDE.md §6): re-running never rewrites a file, it only adds. A
re-encode that produces identical bytes lands on the same name and is skipped.

Runs inside the `tools` container only. Never on the host.
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import hashlib
import io
import json
import os
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageOps
import yaml

# iPhone photos arrive as .heic, which Pillow cannot open unaided. Registering
# pillow-heif's opener makes HEIC just another format to Image.open(). Kept
# optional so the pipeline still runs (minus HEIC) if the wheel is unavailable
# for some future platform.
try:
    import pillow_heif

    pillow_heif.register_heif_opener()
    HEIF_OK = True
except Exception:                       # noqa: BLE001 - any failure means "no HEIC"
    HEIF_OK = False

# --- tunables ---------------------------------------------------------------

DISPLAY_MAX = 1920          # long edge of lightbox images
THUMB_MAX = 400             # long edge of grid thumbnails
JPEG_QUALITY = 85
WEBP_QUALITY = 80
VIDEO_MAX_WIDTH = 1920
VIDEO_CRF = "23"
VIDEO_PRESET = "medium"

# Media is licensed per album via album.yaml. This is the fallback when an
# album.yaml omits the field. See README "Licence".
DEFAULT_LICENSE = "CC BY-SA 4.0"

# A YouTube video id is exactly 11 characters of [A-Za-z0-9_-]. Anything else
# in the `youtube:` list is a mistake we refuse rather than publish.
YOUTUBE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")

PHOTO_EXT = {".jpg", ".jpeg", ".png", ".webp", ".tif", ".tiff", ".heic", ".bmp", ".gif"}
VIDEO_EXT = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".mts", ".3gp"}

Image.MAX_IMAGE_PIXELS = 400_000_000  # generous, but still a decompression-bomb guard


def log(msg: str) -> None:
    print(f"  {msg}", flush=True)


def die(msg: str) -> "NoReturn":  # noqa: F821
    print(f"build_album: error: {msg}", file=sys.stderr)
    sys.exit(1)


def short_hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:12]


def write_immutable(path: Path, data: bytes) -> bool:
    """Write only if absent. Returns True if it actually wrote."""
    if path.exists():
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)
    return True


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        die(f"{cmd[0]} failed ({proc.returncode})\n"
            f"  cmd: {' '.join(cmd)}\n"
            f"  {proc.stderr.strip()[-1500:]}")
    return proc


# --- images -----------------------------------------------------------------

def encode_jpeg(img: Image.Image, max_edge: int) -> tuple[bytes, int, int]:
    im = img.copy()
    im.thumbnail((max_edge, max_edge), Image.LANCZOS)
    if im.mode in ("RGBA", "LA", "P"):
        im = im.convert("RGBA")
        flat = Image.new("RGB", im.size, (255, 255, 255))
        flat.paste(im, mask=im.split()[-1])
        im = flat
    elif im.mode != "RGB":
        im = im.convert("RGB")
    buf = io.BytesIO()
    # No exif= argument: EXIF is dropped, which strips GPS and camera serials
    # from photos taken at a public event.
    im.save(buf, "JPEG", quality=JPEG_QUALITY, optimize=True, progressive=True)
    return buf.getvalue(), im.width, im.height


def encode_webp(img: Image.Image, max_edge: int) -> tuple[bytes, int, int]:
    im = img.copy()
    im.thumbnail((max_edge, max_edge), Image.LANCZOS)
    if im.mode not in ("RGB", "RGBA"):
        im = im.convert("RGB")
    buf = io.BytesIO()
    im.save(buf, "WEBP", quality=WEBP_QUALITY, method=6)
    return buf.getvalue(), im.width, im.height


def build_photo(src: Path, out: Path) -> dict:
    with Image.open(src) as raw:
        raw.load()
        # Honour the EXIF orientation flag, then discard it.
        img = ImageOps.exif_transpose(raw)

        disp_bytes, w, h = encode_jpeg(img, DISPLAY_MAX)
        thumb_bytes, tw, th = encode_webp(img, THUMB_MAX)

    disp_name = f"{short_hash(disp_bytes)}.jpg"
    thumb_name = f"{short_hash(thumb_bytes)}.webp"
    wrote_d = write_immutable(out / "display" / disp_name, disp_bytes)
    wrote_t = write_immutable(out / "thumb" / thumb_name, thumb_bytes)
    log(f"photo {src.name} -> {disp_name} {w}x{h} "
        f"({'new' if wrote_d or wrote_t else 'unchanged'})")

    return {
        "type": "image",
        "id": disp_name[:12],
        "w": w,
        "h": h,
        "thumb": f"thumb/{thumb_name}",
        "src": f"display/{disp_name}",
        "title": src.stem.replace("_", " ").replace("-", " "),
    }


# --- video ------------------------------------------------------------------

def probe(path: Path) -> dict:
    proc = run(["ffprobe", "-v", "error", "-print_format", "json",
                "-show_streams", "-show_format", str(path)])
    return json.loads(proc.stdout)


def video_dims(meta: dict) -> tuple[int, int]:
    for s in meta.get("streams", []):
        if s.get("codec_type") == "video":
            return int(s.get("width", 0)), int(s.get("height", 0))
    return 0, 0


def build_video(src: Path, out: Path, tmpdir: Path) -> dict:
    meta = probe(src)
    duration = float(meta.get("format", {}).get("duration", 0) or 0)

    tmp_mp4 = tmpdir / f"{src.stem}.enc.mp4"
    if tmp_mp4.exists():
        tmp_mp4.unlink()
    log(f"video {src.name} -> transcoding ({duration:.0f}s)")
    run([
        "ffmpeg", "-nostdin", "-v", "error", "-y",
        "-i", str(src),
        # Never upscale; force even dimensions for yuv420p.
        "-vf", f"scale='min({VIDEO_MAX_WIDTH},iw)':-2",
        "-c:v", "libx264", "-crf", VIDEO_CRF, "-preset", VIDEO_PRESET,
        "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "128k", "-ac", "2",
        # faststart puts the moov atom first so the browser can start playing
        # before the whole file arrives -- essential with Range/slice caching.
        "-movflags", "+faststart",
        str(tmp_mp4),
    ])

    mp4_bytes = tmp_mp4.read_bytes()
    mp4_name = f"{short_hash(mp4_bytes)}.mp4"
    write_immutable(out / "video" / mp4_name, mp4_bytes)
    w, h = video_dims(probe(tmp_mp4))

    # Poster frame: 1s in, or 10% through for very short clips.
    seek = min(1.0, duration / 10) if duration else 0.0
    tmp_png = tmpdir / f"{src.stem}.poster.png"
    if tmp_png.exists():
        tmp_png.unlink()
    run(["ffmpeg", "-nostdin", "-v", "error", "-y",
         "-ss", f"{seek:.2f}", "-i", str(tmp_mp4),
         "-frames:v", "1", str(tmp_png)])

    with Image.open(tmp_png) as raw:
        raw.load()
        poster_bytes, _, _ = encode_jpeg(raw, DISPLAY_MAX)
        thumb_bytes, _, _ = encode_webp(raw, THUMB_MAX)

    poster_name = f"{short_hash(poster_bytes)}.jpg"
    thumb_name = f"{short_hash(thumb_bytes)}.webp"
    write_immutable(out / "video" / poster_name, poster_bytes)
    write_immutable(out / "thumb" / thumb_name, thumb_bytes)

    tmp_mp4.unlink(missing_ok=True)
    tmp_png.unlink(missing_ok=True)
    log(f"video {src.name} -> {mp4_name} {w}x{h}")

    return {
        "type": "video",
        "id": mp4_name[:12],
        "w": w,
        "h": h,
        "thumb": f"thumb/{thumb_name}",
        "src": f"video/{mp4_name}",
        "poster": f"video/{poster_name}",
        "title": src.stem.replace("_", " ").replace("-", " "),
    }


# --- youtube ----------------------------------------------------------------

def parse_youtube(raw, yaml_path: Path) -> list[str]:
    """Validate album.yaml's `youtube:` field into a list of video ids.

    This is strict on purpose. `youtube: <a url>` is a single string, and the
    obvious `for vid in youtube` iterates a string one CHARACTER at a time --
    so a pasted channel URL silently became 34 items with ids "h", "t", "t"...
    each rendering as a dead tile in the gallery. Publishing 34 broken embeds
    without a word is far worse than refusing to build.
    """
    if raw is None or raw == "":
        return []

    if isinstance(raw, str):
        die(f"{yaml_path}: 'youtube' must be a LIST of video ids, not a single "
            f"string.\n"
            f"  Got: {raw!r}\n"
            f"{_youtube_hint(raw)}"
            f"  Correct form:\n"
            f"    youtube:\n"
            f"      - dQw4w9WgXcQ\n"
            f"      - kJQP7kiw5Fk")

    if not isinstance(raw, (list, tuple)):
        die(f"{yaml_path}: 'youtube' must be a list of video ids, "
            f"got {type(raw).__name__}")

    ids: list[str] = []
    for entry in raw:
        vid = str(entry).strip()
        if not vid:
            continue
        if not YOUTUBE_ID_RE.match(vid):
            die(f"{yaml_path}: {vid!r} is not a YouTube video id.\n"
                f"  An id is exactly 11 characters of letters, digits, - and _.\n"
                f"{_youtube_hint(vid)}"
                f"  A channel or playlist URL cannot be used: list the individual\n"
                f"  videos you want in the album.")
        ids.append(vid)
    return ids


def _youtube_hint(value: str) -> str:
    """Explain what the offending value actually is, so the fix is obvious."""
    m = (re.search(r"(?:youtu\.be/|/shorts/|/embed/)([A-Za-z0-9_-]{11})", value)
         or re.search(r"[?&]v=([A-Za-z0-9_-]{11})", value))
    if m:
        return f"  That URL's video id is: {m.group(1)}\n"

    # A playlist is the other thing people reach for, and it looks enough like
    # an id to be confusing. It is not one: this project embeds individual
    # videos, so a playlist has to be expanded into the videos you want.
    if re.search(r"[?&]list=", value) or re.match(r"^(PL|UU|LL|RD|OL|FL)[A-Za-z0-9_-]{10,}$", value):
        return ("  That looks like a PLAYLIST id, not a video id.\n"
                "  This gallery embeds individual videos, so open the playlist and\n"
                "  list the ids of the videos you actually want in the album --\n"
                "  each is the 11 characters after 'v=' in the video's own URL.\n")

    if re.search(r"youtube\.com/(@|c/|channel/|user/)", value):
        return ("  That looks like a CHANNEL url, not a video id. A channel has no\n"
                "  single video to embed; list the individual videos you want.\n")
    return ""


def build_youtube(vid: str) -> dict:
    """YouTube items carry ABSOLUTE urls. The front-end must not prefix /media/.

    Nothing is uploaded to B2 for these.
    """
    vid = str(vid).strip()
    return {
        "type": "youtube",
        "id": vid,
        "w": 1280,
        "h": 720,
        "thumb": f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg",
        "src": f"https://www.youtube.com/watch?v={vid}",
        "title": "",
    }


# --- incremental cache ------------------------------------------------------

def source_key(p: Path) -> str:
    """Cache key for one source file.

    Uses the full path, not just the name: photos/ can contain subdirectories
    (a OneDrive import preserves the source structure), and phones happily
    produce two IMG_0001.JPG in different folders. Keying on the bare name
    would let one silently reuse the other's build output.
    """
    st = p.stat()
    return f"{p!s}:{st.st_size}:{st.st_mtime_ns}"


def load_cache(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def outputs_present(out: Path, item: dict) -> bool:
    if item["type"] == "youtube":
        return True
    rels = [item["thumb"], item["src"]] + ([item["poster"]] if item.get("poster") else [])
    return all((out / r).exists() for r in rels)


# --- main -------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="Build an album from inbox/<slug>/")
    ap.add_argument("slug")
    ap.add_argument("--inbox", default="inbox", help="inbox root (default: inbox)")
    ap.add_argument("--force", action="store_true",
                    help="re-encode everything, ignoring the incremental cache")
    args = ap.parse_args()

    slug = args.slug.strip("/")
    album_dir = Path(args.inbox) / slug
    if not album_dir.is_dir():
        die(f"no such album directory: {album_dir}")

    yaml_path = album_dir / "album.yaml"
    if not yaml_path.is_file():
        die(f"missing {yaml_path}\n"
            f"  Create it with: title, date (YYYY-MM-DD), description, credit, license")

    meta = yaml.safe_load(yaml_path.read_text()) or {}
    for required in ("title", "date"):
        if not meta.get(required):
            die(f"{yaml_path}: '{required}' is required")
    date = str(meta["date"])
    try:
        dt.date.fromisoformat(date)
    except ValueError:
        die(f"{yaml_path}: date must be YYYY-MM-DD, got {date!r}")

    out = album_dir / "_build"
    tmpdir = out / ".tmp"
    for sub in ("thumb", "display", "video"):
        (out / sub).mkdir(parents=True, exist_ok=True)
    tmpdir.mkdir(parents=True, exist_ok=True)

    cache_path = out / ".cache.json"
    cache = {} if args.force else load_cache(cache_path)
    new_cache: dict[str, dict] = {}

    # rglob, not glob: a OneDrive import preserves the source folder structure,
    # so photos/ routinely contains subdirectories. Globbing only the top level
    # would silently drop those files -- the worst kind of bug here, because the
    # album publishes successfully with photos missing.
    photos = sorted((p for p in (album_dir / "photos").rglob("*")
                     if p.is_file() and p.suffix.lower() in PHOTO_EXT),
                    key=lambda p: str(p).lower())
    videos = sorted((p for p in (album_dir / "videos").rglob("*")
                     if p.is_file() and p.suffix.lower() in VIDEO_EXT),
                    key=lambda p: str(p).lower())
    youtube = parse_youtube(meta.get("youtube"), yaml_path)

    if not HEIF_OK and any(p.suffix.lower() == ".heic" for p in photos):
        die("this album contains .heic files but pillow-heif is not available.\n"
            "  Rebuild the tools image: make build")

    print(f"building {slug}: {len(photos)} photo(s), {len(videos)} video(s), "
          f"{len(youtube)} youtube link(s)")

    items: list[dict] = []

    for src in photos:
        key = source_key(src)
        hit = cache.get(key)
        if hit and outputs_present(out, hit):
            log(f"photo {src.name} -> cached")
            items.append(hit)
            new_cache[key] = hit
            continue
        item = build_photo(src, out)
        items.append(item)
        new_cache[key] = item

    for src in videos:
        key = source_key(src)
        hit = cache.get(key)
        if hit and outputs_present(out, hit):
            log(f"video {src.name} -> cached (skipping transcode)")
            items.append(hit)
            new_cache[key] = hit
            continue
        item = build_video(src, out, tmpdir)
        items.append(item)
        new_cache[key] = item

    for vid in youtube:
        items.append(build_youtube(vid))

    if not items:
        die(f"{album_dir} produced no items -- is photos/ or videos/ empty?")

    manifest = {
        "slug": slug,
        "title": meta["title"],
        "date": date,
        "description": meta.get("description", ""),
        "credit": meta.get("credit", ""),
        # Per-album licensing; CC BY-SA 4.0 unless album.yaml says otherwise.
        "license": meta.get("license") or DEFAULT_LICENSE,
        # Every relative path in items[] is resolved against this bucket prefix.
        # The browser turns it into /media/events/<slug>/<path> -- see album.html.
        "base": f"events/{slug}/",
        "generated": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "count": len(items),
        "items": items,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    cache_path.write_text(json.dumps(new_cache, indent=2) + "\n")

    try:
        tmpdir.rmdir()
    except OSError:
        pass

    print(f"built {len(items)} item(s) -> {out}/manifest.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
