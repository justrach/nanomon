#!/usr/bin/env python3
"""Native offscreen feature previews and a labeled contact sheet; never cleanup."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "zig-out/storage-preview")
    parser.add_argument("--skip-build", action="store_true", help="Use the already-built native renderer")
    args = parser.parse_args()
    out = args.output.resolve()
    if not args.skip_build:
        subprocess.run(["zig", "build", "storage-preview-bin", "-Doptimize=ReleaseFast"], cwd=ROOT, check=True)
    renderer = ROOT / "zig-out/bin/nanomon-storage-preview"
    subprocess.run([str(renderer), str(out)], cwd=ROOT, check=True)
    manifest = (ROOT / "build.zig.zon").read_text()
    commit = re.search(r"nanoui#([0-9a-f]+)", manifest).group(1)
    version = re.search(r'"nanoui-([0-9.]+)-', manifest).group(1)
    font = "/System/Library/Fonts/Helvetica.ttc"
    for appearance in ("light", "dark"):
        bg, fg = ((246, 245, 239), (40, 44, 46)) if appearance == "light" else ((25, 27, 29), (235, 236, 232))
        sheet = Image.new("RGB", (2200, 1856), bg)
        draw = ImageDraw.Draw(sheet)
        draw.text((24, 15), f"nanomon · Storage & worktrees · nanoui {version}", font=ImageFont.truetype(font, 34), fill=fg)
        for i, (name, label) in enumerate((("overview", "Overview: two compact new rows"),
                                         ("disk", "Disk: capacity stays separate from I/O"),
                                         ("worktrees", "Review: explicit scan, conservative keep rules"),
                                         ("confirmation", "Confirmation: one checkout, fresh safety checks"))):
            x, y = (i % 2) * 1100, 74 + (i // 2) * 860
            draw.text((x + 16, y), label, font=ImageFont.truetype(font, 24), fill=fg)
            with Image.open(out / f"{appearance}-{name}.png") as image:
                sheet.paste(image.convert("RGB").resize((1100, 820), Image.Resampling.LANCZOS), (x, y + 32))
        draw.text((24, 1810), "Unreleased source · Native offscreen UI · Synthetic readings/paths · No real scan or cleanup", font=ImageFont.truetype(font, 24), fill=fg)
        sheet.save(out / f"storage-worktrees-{appearance}.jpg", quality=93)
    metadata = {"purpose": "Unreleased source feature previews, not installed-app captures",
                "synthetic": True, "real_scan_or_cleanup": False,
                "nanoui_pin": commit, "nanoui_version": version,
                "renderer_sha256": hashlib.sha256(renderer.read_bytes()).hexdigest(),
                "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)),
                "images": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in sorted(out.glob("*.png"))}}
    (out / "provenance.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(out)


if __name__ == "__main__":
    main()
