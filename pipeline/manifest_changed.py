#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Has an album's manifest actually changed, ignoring the build timestamp?

    manifest_changed.py <new-manifest> <installed-manifest>

    exit 0  changed (or nothing installed yet)  -> install it
    exit 1  identical apart from `generated`    -> leave the installed file alone

Every build stamps a fresh `generated` time into manifest.json, so a republish
that produced byte-identical media would still rewrite web/albums/<slug>.json
and generate an empty-but-noisy commit. Comparing with that one field dropped
is what makes republishing genuinely idempotent.
"""

import json
import sys

IGNORED_FIELDS = ("generated",)


def normalise(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    for field in IGNORED_FIELDS:
        doc.pop(field, None)
    # sort_keys so key ordering can never masquerade as a change.
    return json.dumps(doc, sort_keys=True)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    new, installed = sys.argv[1], sys.argv[2]
    try:
        return 1 if normalise(new) == normalise(installed) else 0
    except FileNotFoundError:
        return 0            # nothing installed yet -> definitely a change
    except json.JSONDecodeError:
        return 0            # installed file is corrupt -> replace it


if __name__ == "__main__":
    sys.exit(main())
