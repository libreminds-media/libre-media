#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Remove one item from an album: manifest, build cache, and source original.

    remove_item.py <slug> <id>            report what would be removed
    remove_item.py <slug> <id> --apply    do it

Prints the B2-relative object paths on stdout prefixed with "OBJECT ", so the
caller can delete them; this script never touches the network.

Removing the SOURCE original matters as much as removing the derivatives. Leave
it in inbox/<slug>/photos/ and the next `make publish` rebuilds the photo,
re-uploads it, and puts it back in the album -- a takedown that silently undoes
itself is worse than none.
"""

from __future__ import annotations

import json
import pathlib
import sys


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    apply_ = "--apply" in sys.argv
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    slug, item_id = args

    manifest_path = pathlib.Path(f"web/albums/{slug}.json")
    if not manifest_path.is_file():
        print(f"remove_item: no such album: {manifest_path}", file=sys.stderr)
        return 1
    manifest = json.loads(manifest_path.read_text())

    items = manifest.get("items", [])
    match = [i for i in items if i.get("id") == item_id]
    if not match:
        print(f"remove_item: no item with id {item_id!r} in {slug}", file=sys.stderr)
        print(f"  the album has {len(items)} items; ids look like "
              f"{items[0]['id'] if items else '<none>'}", file=sys.stderr)
        return 1
    item = match[0]

    # B2 objects for this item, relative to events/<slug>/
    objects = [item[k] for k in ("thumb", "src", "poster") if item.get(k)]
    objects = [o for o in objects if not str(o).startswith("http")]
    for o in objects:
        print(f"OBJECT {o}")

    build = pathlib.Path(f"inbox/{slug}/_build")
    local_files = [build / o for o in objects]

    # The source original, found through the incremental build cache: its keys
    # are "<path>:<size>:<mtime_ns>", so the path is everything before the last
    # two colons.
    cache_path = build / ".cache.json"
    cache = {}
    source = None
    if cache_path.is_file():
        try:
            cache = json.loads(cache_path.read_text())
        except json.JSONDecodeError:
            cache = {}
        for key, cached in list(cache.items()):
            if cached.get("id") == item_id:
                source = pathlib.Path(key.rsplit(":", 2)[0])
                break

    print(f"ITEM   type={item.get('type')} title={item.get('title')!r} "
          f"{item.get('w')}x{item.get('h')}")
    for f in local_files:
        print(f"LOCAL  {f}  {'exists' if f.exists() else 'missing'}")
    if source:
        print(f"SOURCE {source}  {'exists' if source.exists() else 'missing'}")
    else:
        print("SOURCE <not found in .cache.json -- remove the original by hand "
              "or it will be republished>")
    print(f"COUNT  {len(items)} -> {len(items) - 1}")

    if not apply_:
        print("DRY    nothing changed")
        return 0

    manifest["items"] = [i for i in items if i.get("id") != item_id]
    manifest["count"] = len(manifest["items"])
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"APPLY  rewrote {manifest_path}")

    for f in local_files:
        if f.exists():
            f.unlink()
            print(f"APPLY  removed {f}")
    if source and source.exists():
        source.unlink()
        print(f"APPLY  removed {source}")
    if cache:
        cache = {k: v for k, v in cache.items() if v.get("id") != item_id}
        cache_path.write_text(json.dumps(cache, indent=2) + "\n")
        print(f"APPLY  pruned {cache_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
