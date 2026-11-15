#!/usr/bin/env python3
"""Generate blank D88 templates with the pinned core, without modifying its clone.

Requires Swift and the sibling Bubilator88Core clone (BUBILATOR88_CORE_DIR overrides).
The formatter source is read from the exact Package.resolved revision. Windows
embeds the compressed results and only replaces the disk name at runtime.

Usage: python scripts/make_blank_disk_templates.py [--check]
"""

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify generated files without updating them")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    core = Path(os.environ.get("BUBILATOR88_CORE_DIR", root.parent / "Bubilator88Core"))
    resolved = root / "Bubilator88.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    pin = next(p["state"] for p in json.loads(resolved.read_text())["pins"] if p["identity"] == "bubilator88core")
    source_path = "Sources/PC88Types/D88Disk.swift"
    source = subprocess.check_output(["git", "-C", str(core), "show", f"{pin['revision']}:{source_path}"])
    outputs = {}
    manifest = {"core_revision": pin["revision"], "core_version": pin["version"], "images": {}}
    with tempfile.TemporaryDirectory(prefix="b88-blank-disks-") as temporary:
        directory = Path(temporary)
        source_file = directory / "D88Disk.swift"
        source_file.write_bytes(source)
        executable = directory / ("generate.exe" if os.name == "nt" else "generate")
        subprocess.run(["swiftc", "-parse-as-library", "-package-name", "Bubilator88Core",
                        str(source_file), str(root / "scripts/blank_disk_templates.swift"),
                        "-o", str(executable)], check=True)
        subprocess.run([str(executable), str(directory)], check=True)
        for path in sorted(directory.glob("*.d88")):
            image = path.read_bytes()
            outputs[path.name + ".gz"] = gzip.compress(image, mtime=0)
            manifest["images"][path.name] = {"size": len(image), "sha256": hashlib.sha256(image).hexdigest()}
    outputs["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    destination = root / "Shared/BlankDisks"
    if not args.check:
        destination.mkdir(parents=True, exist_ok=True)
    for name, data in outputs.items():
        path = destination / name
        if args.check:
            # Gzip encoders differ by platform/version; compare decompressed bytes.
            actual = path.read_bytes()
            if name.endswith(".gz"):
                matches = gzip.decompress(actual) == gzip.decompress(data)
            else:
                # Git may check JSON out with CRLF on Windows; compare its contents.
                matches = json.loads(actual) == json.loads(data)
            if not matches:
                raise SystemExit(f"Template differs: {path}")
        else:
            path.write_bytes(data)
        print(f"{'Verified' if args.check else 'Generated'} {name} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
