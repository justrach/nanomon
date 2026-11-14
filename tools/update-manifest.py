#!/usr/bin/env python3
"""Update archive checksums without discarding other platforms' entries."""
import hashlib
import json
from pathlib import Path
import re
import sys


def merge(version, manifest, archives):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", version):
        raise ValueError("invalid version")
    data = json.loads(manifest.read_text())
    if data.get("version") != version or not isinstance(data.get("files"), dict):
        raise ValueError("manifest version/files mismatch")
    for archive in archives:
        if archive.name not in ("nanomon-macos-arm64.zip", "nanomon-linux-aarch64.tar.gz", "nanomon-linux-x86_64.tar.gz"):
            raise ValueError("unexpected release archive")
        data["files"][archive.name] = {"sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
    temporary = manifest.with_suffix(".json.new")
    temporary.write_text(json.dumps(data, separators=(",", ":")) + "\n")
    temporary.replace(manifest)


if __name__ == "__main__":
    merge(sys.argv[1], Path(sys.argv[2]), [Path(p) for p in sys.argv[3:]])
