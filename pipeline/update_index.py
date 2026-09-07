#!/usr/bin/env python3
"""Rebuild web/albums/index.json from every web/albums/<slug>.json.

index.json is what web/index.html reads to draw the album list. It is derived
state -- deleting it and re-running this script reproduces it exactly.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ALBUMS = Path("web/albums")


def main() -> int:
    if not ALBUMS.is_dir():
        print(f"update_index: no such directory: {ALBUMS}", file=sys.stderr)
        return 1

    entries = []
    for path in sorted(ALBUMS.glob("*.json")):
        if path.name == "index.json":
            continue
        try:
            m = json.loads(path.read_text())
        except json.JSONDecodeError as e:
            print(f"update_index: skipping malformed {path}: {e}", file=sys.stderr)
            continue

        items = m.get("items") or []
        cover = next((i for i in items if i.get("type") == "image"), None) \
            or (items[0] if items else None)

        entries.append({
            "slug": m.get("slug", path.stem),
            "title": m.get("title", path.stem),
            "date": m.get("date", ""),
            "description": m.get("description", ""),
            "credit": m.get("credit", ""),
            "base": m.get("base", f"events/{path.stem}/"),
            "count": m.get("count", len(items)),
            "cover": (cover or {}).get("thumb", ""),
            # Absolute cover urls (youtube) must not be prefixed with /media/.
            "cover_absolute": bool(cover and str(cover.get("thumb", "")).startswith("http")),
        })

    # Newest event first; ties broken by slug so the order is stable in git.
    entries.sort(key=lambda e: (e["date"], e["slug"]), reverse=True)

    out = ALBUMS / "index.json"
    out.write_text(json.dumps({"albums": entries}, indent=2) + "\n")
    print(f"index.json: {len(entries)} album(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
