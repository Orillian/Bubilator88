#!/usr/bin/env python3
"""
extract_loc_keys.py — list the localization keys the Swift compiler extracted
from a build, optionally reporting which ones the String Catalog is missing.

Usage:
    scripts/extract_loc_keys.py [--missing] [FILE_STEM ...]

    FILE_STEM   Swift file base names to restrict to, e.g. `TracePane`.
                With none given, every extracted file is scanned.
    --missing   Print only keys absent from Localizable.xcstrings.

Why this exists: `SWIFT_EMIT_LOC_STRINGS = YES` makes the compiler write a
`.stringsdata` file per Swift file into the build intermediates, holding exactly
the keys SwiftUI will look up at runtime. That matters because a
`LocalizedStringKey` built from an interpolated literal is *not* the source text:

    Text("FM \\(ch + 1): muted")   →   key "FM %lld: muted"

Guessing those specifiers by hand is a good way to ship a string that silently
never resolves. Xcode fills the catalog in automatically when the catalog is
opened in its editor, but a command-line build does not, so this reads the same
data the compiler produced.
"""

import json
import plistlib
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "Bubilator88/Resources/Localizable.xcstrings"


def derived_data_dir() -> Path | None:
    """Locate the app target's build intermediates.

    There is one directory per configuration and architecture, and one
    DerivedData folder each for the bare project (`Bubilator88-*`) and the
    development workspace (`Bubilator88Dev-*`), or `build/` in the repository
    when the workspace is set to build there. Pick whichever holds the most
    recently written .stringsdata — sorting by name would prefer Release over
    Debug and happily read a stale build.
    """
    objects = "Bubilator88.build/*/Bubilator88.build/Objects-normal/*"
    roots = [
        root
        for pattern in ("Bubilator88-*", "Bubilator88Dev-*")
        for root in Path.home().glob(f"Library/Developer/Xcode/DerivedData/{pattern}/Build/Intermediates.noindex")
    ]
    # A workspace whose settings put derived data next to it builds into `build/`.
    roots.append(Path(__file__).resolve().parent.parent / "build/Intermediates.noindex")
    candidates = [d for root in roots for d in root.glob(objects) if any(d.glob("*.stringsdata"))]
    if not candidates:
        return None
    return max(candidates, key=lambda d: max(f.stat().st_mtime for f in d.glob("*.stringsdata")))


def load_stringsdata(path: Path) -> list[dict]:
    """Read one .stringsdata file. It is JSON in recent toolchains, plist before."""
    raw = path.read_bytes()
    try:
        data = json.loads(raw)
    except ValueError:
        data = plistlib.loads(raw)
    entries = []
    for table in (data.get("tables") or {}).values():
        entries.extend(table)
    return entries


def main(argv: list[str]) -> int:
    only_missing = "--missing" in argv
    stems = [a for a in argv[1:] if not a.startswith("-")]

    objects = derived_data_dir()
    if objects is None:
        print("No build intermediates found. Build the app target first.", file=sys.stderr)
        return 1

    catalog = set(json.loads(CATALOG.read_text())["strings"])

    keys: dict[str, str] = {}
    for path in sorted(objects.glob("*.stringsdata")):
        if stems and path.stem not in stems:
            continue
        for entry in load_stringsdata(path):
            key = entry.get("key")
            if key:
                keys.setdefault(key, path.stem)

    shown = 0
    for key in sorted(keys):
        if only_missing and key in catalog:
            continue
        print(f"{keys[key]:<24} {key!r}")
        shown += 1

    print(f"\n{shown} key(s){' missing from the catalog' if only_missing else ''}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
